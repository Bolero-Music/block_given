# UncleBlockGiven

[![CI](https://github.com/Bolero-Music/uncle_block_given/actions/workflows/ci.yml/badge.svg)](https://github.com/Bolero-Music/uncle_block_given/actions/workflows/ci.yml)
[![Gem Version](https://badge.fury.io/rb/uncle_block_given.svg)](https://rubygems.org/gems/uncle_block_given)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.txt)
![Ruby 3.1+](https://img.shields.io/badge/ruby-%3E%3D%203.1-cc342d)

**Ruby client for EVM smart contracts, inspired by [viem](https://viem.sh).**
Declare a contract class from its ABI and every function becomes a Ruby method. Wallets sign EIP-1559
transactions, connectors (Alchemy first) speak JSON-RPC, and polling helpers wait for receipts, blocks and
events with resumable cursors.

```ruby
UncleBlockGiven.configure do |c|
  c.connector = UncleBlockGiven::Connectors::Alchemy.new(api_key: ENV["ALCHEMY_API_KEY"])
  c.chain = :base
end

class Usdc < UncleBlockGiven::Contract
  abi_file "abis/erc20.json"   # ABIs live in your repo, not in the gem
  address "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
end

wallet = UncleBlockGiven::Wallet.new(private_key: ENV["PRIVATE_KEY"])
usdc = Usdc.new(wallet: wallet)

usdc.balance_of(wallet.address)                 # => 12_500_000  (eth_call, decoded)
tx = usdc.transfer(to: "0x7099...79C8", amount: 1e6)  # signs + broadcasts, returns UncleBlockGiven::Transaction
receipt = tx.wait!                              # polls until mined, raises if reverted
usdc.events_from(receipt)                       # => [#<UncleBlockGiven::Event Transfer {from:, to:, value: 1000000}>]
```

## Table of contents

- [Installation](#installation)
- [Configuration](#configuration)
  - [Connectors](#connectors)
  - [Chains](#chains)
- [Contracts](#contracts)
  - [Calling functions](#calling-functions)
  - [Transactions & receipts](#transactions--receipts)
  - [Reliable writes: sign first, broadcast later](#reliable-writes-sign-first-broadcast-later)
  - [Reverts](#reverts)
- [Events](#events)
- [Polling](#polling)
  - [Listing, stopping and killing watchers](#listing-stopping-and-killing-watchers)
  - [How watchers behave](#how-watchers-behave)
- [Wallet](#wallet)
- [Client (low level)](#client-low-level)
- [Utils](#utils)
- [Testing your code](#testing-your-code)
- [Compatibility](#compatibility)
  - [Rails integration](#rails-integration)
- [Development](#development)
  - [Versioning & releases](#versioning--releases)
- [Security](#security)
- [Contributing](#contributing)
- [Roadmap](#roadmap)
- [License](#license)

## Installation

```ruby
# Gemfile
gem "uncle_block_given"
```

UncleBlockGiven depends on the [`eth`](https://github.com/q9f/eth.rb) gem for secp256k1, keccak and ABI primitives.
Its native extension needs libsecp256k1; on macOS `brew install secp256k1` then
`gem install rbsecp256k1 -- --with-system-library` if the bundled build fails.

Requires Ruby >= 3.1.

## Configuration

```ruby
UncleBlockGiven.configure do |c|
  c.connector = UncleBlockGiven::Connectors::Alchemy.new(api_key: ENV["ALCHEMY_API_KEY"])
  c.chain = :base               # UncleBlockGiven::Chains::BASE, "base-sepolia", 8453 ... all work
  c.polling_interval = 2.0      # seconds between polls (receipts, blocks, events)
  c.timeout = 180               # seconds before Transaction#wait gives up
  c.confirmations = 1           # blocks to wait for in Transaction#wait
  c.gas_multiplier = 1.2        # margin applied to eth_estimateGas
  c.base_fee_multiplier = 1.2   # maxFeePerGas = baseFee * 1.2 + priorityFee (viem default)
  c.abi_path = "abis"           # optional: directory Contract.abi_file resolves relative paths against
  c.logger = Logger.new($stdout, level: Logger::DEBUG)  # logs every JSON-RPC call at DEBUG
end

UncleBlockGiven.client   # default UncleBlockGiven::Client built from the config
```

### Connectors

| Connector                                 | Usage                                                                                                   |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `UncleBlockGiven::Connectors::Alchemy.new(api_key:)` | Endpoint derived from the chain (`base-mainnet.g.alchemy.com`, ...). One instance serves every network. |
| `UncleBlockGiven::Connectors::Http.new(url:)`        | Any JSON-RPC endpoint (Hardhat, Anvil, Infura...). Without `url:` it uses the chain's public RPC.       |
| `UncleBlockGiven::Connectors::Stub.new(...)`         | In-memory responses for tests (see below).                                                              |

All HTTP connectors retry on 429/5xx/timeouts with exponential backoff (`retries:`, `retry_delay:`),
support `batch`, and never print API keys in `inspect`.

### Chains

Built in: `MAINNET`, `SEPOLIA`, `BASE`, `BASE_SEPOLIA`, `POLYGON`, `POLYGON_AMOY`, `ARBITRUM`,
`ARBITRUM_SEPOLIA`, `OPTIMISM`, `OPTIMISM_SEPOLIA`, `LOCALHOST` (31337). Custom:

```ruby
fork = UncleBlockGiven::Chain.new(id: 31_337, name: "Base fork", rpc_urls: ["http://127.0.0.1:8545"])
client = UncleBlockGiven::Client.new(chain: fork, connector: UncleBlockGiven::Connectors::Http.new)
```

## Contracts

The gem ships no ABI: keep them in your repository (`abis/*.json`, or the Hardhat/Foundry artifacts) and
point each contract class at its file. With `UncleBlockGiven.config.abi_path = Rails.root.join("abis")` relative
names resolve from that directory.

```ruby
class CatalogShares < UncleBlockGiven::Contract
  abi_file "CatalogShares.json"             # ABI array, Hardhat/Foundry artifact ({ "abi": [...] }), or JSON string via `abi`
  address "0x..."                            # optional default address
  chain :base                                # optional: pins the chain regardless of the global config
end

shares = CatalogShares.new(wallet: wallet)            # default address
shares = CatalogShares.at("0x...", wallet: wallet)    # explicit address
shares = CatalogShares.at("0x...")                    # read-only (no wallet)
```

### Calling functions

Every ABI function is available in snake_case. `view`/`pure` functions run `eth_call` and return decoded
values; the others sign and broadcast a transaction and return a `UncleBlockGiven::Transaction`.

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
vault.deposit(amount, tx: { value: UncleBlockGiven::Utils.parse_ether("0.1"), gas: 200_000, nonce: 12 })
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
tx.wait!                     # raises UncleBlockGiven::TransactionRevertedError when status is :reverted
tx.status                    # :success / :reverted (mined), :pending (in the mempool), :unknown (never seen or dropped)
tx.confirmations             # blocks since inclusion (non-blocking), tx.confirmed?(5)
client.transaction("0x...")  # the same handle for a hash you persisted earlier
```

### Reliable writes: sign first, broadcast later

A transaction hash is the keccak of the signed bytes, so it is known **before** anything is sent.
`prepare_write` (or `Wallet#signed_transaction`) signs without broadcasting; persist the hash and
nonce, then broadcast. If the RPC call times out you still know exactly which transaction to look for,
and a same-nonce replacement can never be mined twice.

```ruby
signed = registry.prepare_write(:record, movement_id, tx: { nonce: call.nonce })
signed.hash, signed.nonce, signed.raw          # known now; signed.to_h for persistence
call.update!(tx_hash: signed.hash, status: :submitted)
signed.broadcast                               # eth_sendRawTransaction, returns the Transaction

# later, one tick of your outbox worker (possibly another process: rebuild from the persisted bytes)
signed = UncleBlockGiven::SignedTransaction.from_raw(call.raw_tx, wallet: wallet, interface: registry.interface)
tx = signed.transaction                                   # same as client.transaction(call.tx_hash)
case tx.status
when :success  then call.confirmed! if tx.confirmed?(5)   # registry.events_from(tx.receipt) has the logs
when :reverted then call.failed!
when :unknown  then signed.broadcast                      # dropped by the node: resend the same bytes
when :pending  then signed.replacement.broadcast if call.submitted_at < 5.minutes.ago
end
```

`replacement(fee_multiplier: 1.125)` re-signs the same payload and nonce with fees raised by the
multiplier (at least 10%, otherwise nodes reject it as underpriced) and never below a fresh estimate. If
the original gets mined first, the replacement is rejected for its nonce and `tx.status` tells you so.

### Reverts

`eth_call`, `eth_estimateGas` and sends that revert raise `UncleBlockGiven::ContractRevertError`.
`Error(string)` and `Panic(uint256)` reasons are decoded; custom errors are decoded with the contract ABI:

```ruby
begin
  usdc.transfer(to: addr, amount: 10**12)
rescue UncleBlockGiven::ContractRevertError => e
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

`UncleBlockGiven::Event` exposes `name`, `args` (snake_case symbols, declaration order), `[]`, `address`, `block_number`,
`transaction_hash`, `log_index`. Indexed `string`/`bytes`/arrays only carry their keccak hash, as on-chain.

## Polling

```ruby
client = UncleBlockGiven.client

client.watch_block_number(emit_missed: true) { |n| ... }     # UncleBlockGiven::Watcher
client.watch_blocks { |block| ... }
client.watch_logs(address: addr, topics: [...]) { |logs| ... }
client.wait_for_transaction_receipt(hash, confirmations: 3)
client.get_logs_in_chunks(address: addr, from_block: 1, to_block: :latest)   # splits by max_block_range

# generic blocking poll: returns the first truthy value or raises UncleBlockGiven::TimeoutError
UncleBlockGiven::Poller.poll(interval: 1, timeout: 60) { client.get_transaction_receipt(hash) }
```

### Listing, stopping and killing watchers

Every running watcher is registered under a unique id (auto-generated, or the `id:` you pass), and its
thread is named `uncle_block_given:<id>` so it shows up in `Thread.list` and in thread dumps.

```ruby
usdc.watch_event(:Transfer, id: "usdc-deposits") { |e| ... }
UncleBlockGiven.client.watch_block_number { |n| ... }               # id auto-generated: "block_number-3fa9c1"

UncleBlockGiven.watchers                          # => running watchers, oldest first (alias UncleBlockGiven::Watcher.all)
UncleBlockGiven.watchers.map(&:to_h)              # id, name, status, cursor, ticks, started_at, last_tick_at, last_error...
UncleBlockGiven::Watcher.find("usdc-deposits")    # => the watcher, nil if not running
UncleBlockGiven::Watcher.stop("usdc-deposits", join: 5)   # graceful: finishes the current tick
UncleBlockGiven::Watcher.kill("usdc-deposits")            # forceful: Thread#kill, for a tick stuck in a network call
UncleBlockGiven::Watcher.stop_all(join: 5)                # e.g. in an at_exit / SIGTERM handler
```

Starting a second watcher with an id that is already running raises, which protects against double
starts after a code reload. `UncleBlockGiven.reset!` stops every watcher.

### How watchers behave

- One Ruby thread per watcher, sleeping on a condition variable between ticks (`stop` wakes it
  immediately). Each tick fetches the new block range, yields, and keeps only the last processed block
  number: nothing accumulates inside the gem. Errors are logged (or handed to `on_error`) and the range is
  retried on the next tick.
- Large gaps are processed in chunks of `max_block_range` blocks (default 2000, provider limits apply), so
  resuming after hours of downtime works.
- `confirmations:` keeps the watcher N blocks behind the head, so logs from shallow reorgs are never delivered.
- Watchers live in the process that started them. With Puma in cluster mode or Sidekiq, start them in a
  single dedicated process (a `bin/indexer`, a Rake task, a one-replica container), not in every web worker.
- Nothing is persisted by the gem. Own the cursor in your app:

```ruby
# app/indexers/usdc_deposit_indexer.rb — started once at boot by the dedicated process
class UsdcDepositIndexer
  def start
    cursor = IndexerCursor.find_or_create_by!(name: "usdc_deposits") { |c| c.block = UncleBlockGiven.client.block_number }
    usdc = Usdc.new

    @watcher = usdc.watch_event(
      :Transfer, args: { to: TREASURY },
      from_block: cursor.block + 1,          # resume where the previous process stopped
      confirmations: 2,                      # reorg margin
      on_progress: ->(_from, to) { cursor.update!(block: to) } # runs after the range's events were handled
    ) { |event| Deposit.upsert_from_event(event) }   # idempotent on (transaction_hash, log_index)

    @watcher.on_error { |e, _| Sentry.capture_exception(e) }
    at_exit { @watcher.stop.join(5) }
  end
end
```

`on_progress` is called after the block you passed processed every event of the range, so a crash in
between simply replays that range on restart. `watcher.cursor` exposes the same value in memory.

## Wallet

```ruby
wallet = UncleBlockGiven::Wallet.new(private_key: ENV["PRIVATE_KEY"])   # with or without 0x
UncleBlockGiven::Wallet.generate
wallet.address, wallet.balance, wallet.nonce
wallet.sign_message("hello")                # EIP-191
wallet.sign_typed_data(typed_data)          # EIP-712
wallet.send_transaction(to: addr, value: UncleBlockGiven::Utils.parse_ether("0.01")).wait
wallet.send_transaction(to: addr, data: "0x...", gas_price: UncleBlockGiven::Utils.parse_gwei("2"))  # legacy type-0 tx
wallet.prepare_transaction(to: addr, data: "0x...")   # resolved nonce/gas/fees without signing
wallet.signed_transaction(to: addr, data: "0x...")    # signed, not broadcast: #hash, #nonce, #broadcast, #replacement
```

Missing fields are filled from the client: pending nonce, `eth_estimateGas * gas_multiplier`,
EIP-1559 fees from the latest block's base fee and `eth_maxPriorityFeePerGas`.

## Client (low level)

`UncleBlockGiven::Client` mirrors viem's public client: `chain_id`, `block_number`, `get_block`, `get_balance`,
`get_transaction_count`, `get_code`, `get_storage_at`, `call`, `estimate_gas`, `gas_price`,
`estimate_fees_per_gas`, `send_raw_transaction`, `get_transaction`, `get_transaction_receipt`, `get_logs`,
plus `request(method, *params)` and `batch([[method, params], ...])` for anything else. Results use
snake_case symbol keys with integer quantities.

## Utils

```ruby
UncleBlockGiven::Utils.parse_units("1.5", 6)      # => 1_500_000
UncleBlockGiven::Utils.format_units(1_500_000, 6) # => "1.5"
UncleBlockGiven::Utils.parse_ether("0.1"), UncleBlockGiven::Utils.format_ether(wei), parse_gwei, format_gwei
UncleBlockGiven::Utils.keccak256("transfer(address,uint256)")  # => "0xa9059cbb..."
UncleBlockGiven::Utils.checksum_address(addr), UncleBlockGiven::Utils.address?(str), UncleBlockGiven::Utils.to_hex(255), hex_to_int("0xff")
```

Token helpers are one method away in your own contract class:

```ruby
class Erc20 < UncleBlockGiven::Contract
  abi_file "erc20.json"
  def decimals = @decimals ||= read(:decimals)
  def parse_amount(value) = UncleBlockGiven::Utils.parse_units(value, decimals)    # "1.5" -> 1_500_000
  def format_amount(value) = UncleBlockGiven::Utils.format_units(value, decimals)  # 1_500_000 -> "1.5"
end
```

## Testing your code

`UncleBlockGiven::Connectors::Stub` answers JSON-RPC calls from memory:

```ruby
stub = UncleBlockGiven::Connectors::Stub.new(
  "eth_call" => "0x" + "1".rjust(64, "0"),
  "eth_blockNumber" => UncleBlockGiven::Connectors::Stub.sequence("0x10", "0x11"),   # consumed in order
  "eth_getTransactionReceipt" => ->(params) { receipts[params.first] }
)
UncleBlockGiven.configure { |c| c.connector = stub; c.chain = :base; c.polling_interval = 0 }
stub.calls               # => [["eth_call", [...]], ...]
stub.calls_for("eth_sendRawTransaction")
```

## Compatibility

|        | Supported                                  | Verified by                                                   |
| ------ | ------------------------------------------ | ------------------------------------------------------------- |
| Ruby   | >= 3.1 (3.1, 3.2, 3.3, 3.4)                | CI matrix + local run on each version                         |
| Rails  | optional, 7.0 / 7.1 / 7.2 / 8.0            | full suite run with Rails loaded (`gemfiles/rails_*.gemfile`) |
| `eth`  | ~> 0.5, >= 0.5.17 (tuple ABI support)      | pinned in the gemspec                                         |
| stdlib | `bigdecimal`, `logger` declared explicitly | bundled gems in Ruby 3.4 / 3.5                                |

UncleBlockGiven has no runtime dependency on Rails or ActiveSupport: it is plain Ruby and works in scripts,
Sidekiq workers, Rails apps or Hanami alike.

### Rails integration

```ruby
# config/initializers/uncle_block_given.rb
UncleBlockGiven.configure do |c|
  c.connector = UncleBlockGiven::Connectors::Alchemy.new(api_key: Rails.application.credentials.alchemy_api_key)
  c.chain = Rails.env.production? ? :base : :base_sepolia
  c.abi_path = Rails.root.join("abis")
end
```

A railtie (loaded automatically when Rails is present) routes UncleBlockGiven's logs to `Rails.logger`
unless the initializer sets `c.logger` itself. Contract classes live wherever you want
(`app/contracts/usdc.rb` works with Zeitwerk out of the box) and ABI files in `abis/`.

## Development

```bash
bin/setup                            # bundle install (+ libsecp256k1 fallback)
bundle exec rspec                    # unit suite (Stub connector, no network)
COVERAGE=1 bundle exec rspec         # + SimpleCov report in coverage/ (minimum 90% lines)
bundle exec rubocop
ALCHEMY_API_KEY=... bin/console      # IRB with UncleBlockGiven configured for UNCLE_BLOCK_GIVEN_CHAIN (default base)

bundle exec rake ci                  # specs + rubocop + gem build

# Ruby / Rails matrix (Docker for the Rubies you do not have locally)
bin/matrix                           # Ruby 3.2, 3.3, 3.4
bin/matrix rails 7.2                 # Rails 7.2 compat suite, local Ruby
bin/matrix rails 8.0 3.4             # Rails 8.0 under Ruby 3.4
```

CI runs the suite on Ruby 3.1 to 3.4 and against Rails 7.0, 7.1, 7.2 and 8.0 (`.github/workflows/ci.yml`).

### Versioning & releases

UncleBlockGiven follows [Semantic Versioning](https://semver.org): breaking changes to the public API
(`UncleBlockGiven::Contract`, `Wallet`, `Client`, connectors, `Utils`) bump the major version, additions the minor,
fixes the patch. Every change is listed in `CHANGELOG.md`. Dependency policy: Ruby versions are dropped
only once they reach end of life, Rails versions are tested while they receive security fixes, and the `eth`
constraint is only tightened when a feature needs it.

To release: bump `lib/uncle_block_given/version.rb`, move the `Unreleased` notes under the new version in `CHANGELOG.md`,
commit, then push a `vX.Y.Z` tag. The release workflow checks the tag against the version, runs the suite and
publishes through RubyGems trusted publishing (no API key in CI). `bundle exec rake release` does the same
from a maintainer machine with RubyGems credentials.

## Security

- Private keys never leave `UncleBlockGiven::Wallet`; `inspect` hides them and API keys are masked in every log and
  error message (`Http#redact`).
- Never commit keys: use `ENV`, Rails credentials or Hardhat vars, and keep `.env` out of git (see `.env.example`).
- Report a vulnerability privately to remi@boleromusic.com rather than in a public issue. See [SECURITY.md](SECURITY.md).

## Contributing

Bug reports and pull requests are welcome on [GitHub](https://github.com/Bolero-Music/uncle_block_given). Please read
[CONTRIBUTING.md](CONTRIBUTING.md) (setup, test matrix, conventions) and the
[code of conduct](CODE_OF_CONDUCT.md).

## Roadmap

- Contract deployment (`Contract.deploy`)
- Multi-contract indexer helper with pluggable cursor store
- Human-readable ABI (`parse_abi("function transfer(address to, uint256 amount)")`)
- WebSocket connector for push-based subscriptions
- Multicall batching of reads

## License

Released under the [MIT License](LICENSE.txt).
