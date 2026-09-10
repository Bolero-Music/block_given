# Vium

A small, explicit Ruby toolkit to read from and write to EVM smart contracts, inspired by
[viem](https://viem.sh). Declare a contract class from its ABI and every function becomes a Ruby method;
wallets sign EIP-1559 transactions; connectors (Alchemy first) talk JSON-RPC; polling helpers wait for
receipts, blocks and events.

```ruby
Vium.configure do |c|
  c.connector = Vium::Connectors::Alchemy.new(api_key: ENV["ALCHEMY_API_KEY"])
  c.chain = :base
end

class Usdc < Vium::Contract
  abi_file "abis/erc20.json"
  address "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
end

wallet = Vium::Wallet.new(private_key: ENV["PRIVATE_KEY"])
usdc = Usdc.new(wallet: wallet)

usdc.balance_of(wallet.address)                 # => 12_500_000  (eth_call, decoded)
tx = usdc.transfer(to: "0x7099...79C8", amount: 1e6)  # signs + broadcasts, returns Vium::Transaction
receipt = tx.wait!                              # polls until mined, raises if reverted
usdc.events_from(receipt)                       # => [#<Vium::Event Transfer {from:, to:, value: 1000000}>]
```

## Compatibility

| | Supported | Verified by |
|---|---|---|
| Ruby | >= 3.1 (3.1, 3.2, 3.3, 3.4) | CI matrix + local run on each version |
| Rails | optional, 7.0 / 7.1 / 7.2 / 8.0 | full suite run with Rails loaded (`gemfiles/rails_*.gemfile`) |
| `eth` | ~> 0.5, >= 0.5.17 (tuple ABI support) | pinned in the gemspec |
| stdlib | `bigdecimal`, `logger` declared explicitly | bundled gems in Ruby 3.4 / 3.5 |

Vium has no runtime dependency on Rails or ActiveSupport: it is plain Ruby and works in scripts,
Sidekiq workers, Rails apps or Hanami alike.

### Rails integration

```ruby
# config/initializers/vium.rb
Vium.configure do |c|
  c.connector = Vium::Connectors::Alchemy.new(api_key: Rails.application.credentials.alchemy_api_key)
  c.chain = Rails.env.production? ? :base : :base_sepolia
end
```

A railtie (loaded automatically when Rails is present) routes Vium's logs to `Rails.logger`
unless the initializer sets `c.logger` itself. Contract classes live wherever you want
(`app/contracts/usdc.rb` works with Zeitwerk out of the box).

## Installation

```ruby
# Gemfile
gem "vium"
```

Vium depends on the [`eth`](https://github.com/q9f/eth.rb) gem for secp256k1, keccak and ABI primitives.
Its native extension needs libsecp256k1; on macOS `brew install secp256k1` then
`gem install rbsecp256k1 -- --with-system-library` if the bundled build fails.

Requires Ruby >= 3.1.

## Configuration

```ruby
Vium.configure do |c|
  c.connector = Vium::Connectors::Alchemy.new(api_key: ENV["ALCHEMY_API_KEY"])
  c.chain = :base               # Vium::Chains::BASE, "base-sepolia", 8453 ... all work
  c.polling_interval = 2.0      # seconds between polls (receipts, blocks, events)
  c.timeout = 180               # seconds before Transaction#wait gives up
  c.confirmations = 1           # blocks to wait for in Transaction#wait
  c.gas_multiplier = 1.2        # margin applied to eth_estimateGas
  c.base_fee_multiplier = 1.2   # maxFeePerGas = baseFee * 1.2 + priorityFee (viem default)
  c.logger = Logger.new($stdout, level: Logger::DEBUG)  # logs every JSON-RPC call at DEBUG
end

Vium.client   # default Vium::Client built from the config
```

### Connectors

| Connector | Usage |
|---|---|
| `Vium::Connectors::Alchemy.new(api_key:)` | Endpoint derived from the chain (`base-mainnet.g.alchemy.com`, ...). One instance serves every network. |
| `Vium::Connectors::Http.new(url:)` | Any JSON-RPC endpoint (Hardhat, Anvil, Infura...). Without `url:` it uses the chain's public RPC. |
| `Vium::Connectors::Stub.new(...)` | In-memory responses for tests (see below). |

All HTTP connectors retry on 429/5xx/timeouts with exponential backoff (`retries:`, `retry_delay:`),
support `batch`, and never print API keys in `inspect`.

### Chains

Built in: `MAINNET`, `SEPOLIA`, `BASE`, `BASE_SEPOLIA`, `POLYGON`, `POLYGON_AMOY`, `ARBITRUM`,
`ARBITRUM_SEPOLIA`, `OPTIMISM`, `OPTIMISM_SEPOLIA`, `LOCALHOST` (31337). Custom:

```ruby
fork = Vium::Chain.new(id: 31_337, name: "Base fork", rpc_urls: ["http://127.0.0.1:8545"])
client = Vium::Client.new(chain: fork, connector: Vium::Connectors::Http.new)
```

## Contracts

```ruby
class CatalogShares < Vium::Contract
  abi_file "artifacts/CatalogShares.json"   # ABI array, Hardhat/Foundry artifact, or JSON string
  address "0x..."                            # optional default address
  chain :base                                # optional: pins the chain regardless of the global config
end

shares = CatalogShares.new(wallet: wallet)            # default address
shares = CatalogShares.at("0x...", wallet: wallet)    # explicit address
shares = CatalogShares.at("0x...")                    # read-only (no wallet)
```

### Calling functions

Every ABI function is available in snake_case. `view`/`pure` functions run `eth_call` and return decoded
values; the others sign and broadcast a transaction and return a `Vium::Transaction`.

```ruby
shares.balance_of("0x...")                    # positional
shares.balance_of(account: "0x...")           # keyword (ABI input names, leading _ stripped, snake_cased)
shares.transfer(to: "0x...", amount: 1e6)     # floats are accepted when they are whole numbers
shares.transfer(wallet2, 1_000_000)           # anything responding to #address works as an address
```

Argument coercion: integers accept `Integer`, whole `Float`/`BigDecimal`, decimal or hex strings; tuples accept
`Hash` (component names) or `Array`; `bytes` accept hex or binary strings. Decoded outputs give checksummed
addresses, `0x` hex for bytes, and named tuples as `Hash`. Multiple outputs come back as an `Array`.

Transaction and call overrides live in the reserved `tx:` keyword so they never clash with ABI input names:

```ruby
vault.deposit(amount, tx: { value: Vium::Utils.parse_ether("0.1"), gas: 200_000, nonce: 12 })
shares.balance_of(addr, tx: { block: 20_000_000 })          # historical read
shares.owner_of(1, tx: { from: "0x..." })                    # msg.sender for eth_call
# allowed keys: value gas nonce max_fee_per_gas max_priority_fee_per_gas gas_price from block
```

Explicit API (handles names clashing with Ruby methods, overloads by signature, etc.):

```ruby
shares.read(:balance_of, addr)
shares.write("safeMint(address,bytes)", addr, "0x")
shares.simulate(:buy, 42, tx: { value: price })   # eth_call from the wallet: raises the decoded revert without paying gas
shares.estimate_gas(:buy, 42, tx: { value: price })
shares.encode_function_data(:transfer, to: addr, amount: 1)
shares.decode_function_result(:balance_of, "0x...")
```

### Transactions & receipts

```ruby
tx = shares.transfer(to: addr, amount: 1)
tx.hash                      # "0x..."
tx.explorer_url              # https://basescan.org/tx/0x...
tx.mined?                    # non-blocking
receipt = tx.wait(confirmations: 2, timeout: 300, polling_interval: 1)
receipt.status               # :success / :reverted
receipt.gas_used, receipt.fee, receipt.block_number, receipt.logs
tx.wait!                     # raises Vium::TransactionRevertedError when status is :reverted
```

### Reverts

`eth_call`, `eth_estimateGas` and sends that revert raise `Vium::ContractRevertError`.
`Error(string)` and `Panic(uint256)` reasons are decoded; custom errors are decoded with the contract ABI:

```ruby
begin
  usdc.transfer(to: addr, amount: 10**12)
rescue Vium::ContractRevertError => e
  e.message     # => 'ERC20InsufficientBalance("0xf39F...", 5, 1000000000000)'
  e.error_name  # => "ERC20InsufficientBalance"
  e.args        # => { sender: "0xf39F...", balance: 5, needed: 1000000000000 }
  e.reason      # => "insufficient balance" for Error(string) reverts
end
```

## Events

```ruby
# past events, filtered on indexed args (single value or Array for OR)
usdc.get_events(:Transfer, from_block: 20_000_000, to_block: :latest, args: { to: wallet.address })
usdc.get_events(from_block: 20_000_000)          # every event the ABI knows

# polling in a background thread
watcher = usdc.watch_event(:Transfer, args: { to: wallet.address }) do |event|
  puts "#{event[:from]} sent #{event[:value]} in tx #{event.transaction_hash}"
end
watcher.on_error { |error, _| warn error.message }   # default: logged, polling continues
watcher.stop                                          # alias: unwatch

# decode logs yourself
usdc.decode_logs(receipt.logs)
usdc.events_from(receipt)                             # only this contract's logs
```

`Vium::Event` exposes `name`, `args` (snake_case symbols, declaration order), `[]`, `address`, `block_number`,
`transaction_hash`, `log_index`. Indexed `string`/`bytes`/arrays only carry their keccak hash, as on-chain.

## Polling

```ruby
client = Vium.client

client.watch_block_number(emit_missed: true) { |n| ... }     # Vium::Watcher
client.watch_blocks { |block| ... }
client.watch_logs(address: addr, topics: [...]) { |logs| ... }
client.wait_for_transaction_receipt(hash, confirmations: 3)

# generic blocking poll: returns the first truthy value or raises Vium::TimeoutError
Vium::Poller.poll(interval: 1, timeout: 60) { client.get_transaction_receipt(hash) }
```

Watchers run in their own thread, wake up immediately on `stop`, and keep going after errors.

## Wallet

```ruby
wallet = Vium::Wallet.new(private_key: ENV["PRIVATE_KEY"])   # with or without 0x
Vium::Wallet.generate
wallet.address, wallet.balance, wallet.nonce
wallet.sign_message("hello")                # EIP-191
wallet.sign_typed_data(typed_data)          # EIP-712
wallet.send_transaction(to: addr, value: Vium::Utils.parse_ether("0.01")).wait
wallet.send_transaction(to: addr, data: "0x...", gas_price: Vium::Utils.parse_gwei("2"))  # legacy type-0 tx
wallet.prepare_transaction(to: addr, data: "0x...")   # resolved nonce/gas/fees without signing
```

Missing fields are filled from the client: pending nonce, `eth_estimateGas * gas_multiplier`,
EIP-1559 fees from the latest block's base fee and `eth_maxPriorityFeePerGas`.

## Client (low level)

`Vium::Client` mirrors viem's public client: `chain_id`, `block_number`, `get_block`, `get_balance`,
`get_transaction_count`, `get_code`, `get_storage_at`, `call`, `estimate_gas`, `gas_price`,
`estimate_fees_per_gas`, `send_raw_transaction`, `get_transaction`, `get_transaction_receipt`, `get_logs`,
plus `request(method, *params)` and `batch([[method, params], ...])` for anything else. Results use
snake_case symbol keys with integer quantities.

## Utils

```ruby
Vium::Utils.parse_units("1.5", 6)      # => 1_500_000
Vium::Utils.format_units(1_500_000, 6) # => "1.5"
Vium::Utils.parse_ether("0.1"), Vium::Utils.format_ether(wei), parse_gwei, format_gwei
Vium::Utils.keccak256("transfer(address,uint256)")  # => "0xa9059cbb..."
Vium::Utils.checksum_address(addr), Vium::Utils.address?(str), Vium::Utils.to_hex(255), hex_to_int("0xff")
```

`Vium::ERC20` ships with the OpenZeppelin ABI plus `parse_amount("1.5")` / `format_amount(wei)` using the
token's decimals.

## Testing your code

`Vium::Connectors::Stub` answers JSON-RPC calls from memory:

```ruby
stub = Vium::Connectors::Stub.new(
  "eth_call" => "0x" + "1".rjust(64, "0"),
  "eth_blockNumber" => Vium::Connectors::Stub.sequence("0x10", "0x11"),   # consumed in order
  "eth_getTransactionReceipt" => ->(params) { receipts[params.first] }
)
Vium.configure { |c| c.connector = stub; c.chain = :base; c.polling_interval = 0 }
stub.calls               # => [["eth_call", [...]], ...]
stub.calls_for("eth_sendRawTransaction")
```

## Development

```bash
bundle install
bundle exec rspec                    # unit suite (Stub connector, no network)
COVERAGE=1 bundle exec rspec         # + SimpleCov report in coverage/ (minimum 90% lines)
bundle exec rubocop
ALCHEMY_API_KEY=... bin/console      # IRB with Vium configured for VIUM_CHAIN (default base)

# Rails compatibility suites
BUNDLE_GEMFILE=gemfiles/rails_7.2.gemfile bundle install
RAILS_COMPAT=1 BUNDLE_GEMFILE=gemfiles/rails_7.2.gemfile bundle exec rspec
```

CI runs the suite on Ruby 3.1 to 3.4 and against Rails 7.0, 7.1, 7.2 and 8.0 (`.github/workflows/ci.yml`).

### Versioning & releases

Vium follows [Semantic Versioning](https://semver.org): breaking changes to the public API
(`Vium::Contract`, `Wallet`, `Client`, connectors, `Utils`) bump the major version, additions the minor,
fixes the patch. Every change is listed in `CHANGELOG.md`. Dependency policy: Ruby versions are dropped
only once they reach end of life, Rails versions are tested while they receive security fixes, and the `eth`
constraint is only tightened when a feature needs it.

To release: bump `lib/vium/version.rb`, move the `Unreleased` notes under the new version in `CHANGELOG.md`,
then `bundle exec rake release` (builds the gem, tags `vX.Y.Z`, pushes to rubygems).

## Roadmap

- Contract deployment (`Contract.deploy`)
- Human-readable ABI (`parse_abi("function transfer(address to, uint256 amount)")`)
- WebSocket connector for push-based subscriptions
- Multicall batching of reads

## License

MIT
