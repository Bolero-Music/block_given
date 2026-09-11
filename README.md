# BlockGiven

[![CI](https://github.com/Bolero-Music/block_given/actions/workflows/ci.yml/badge.svg)](https://github.com/Bolero-Music/block_given/actions/workflows/ci.yml)
[![Gem Version](https://badge.fury.io/rb/block_given.svg)](https://rubygems.org/gems/block_given)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.txt)
![Ruby 3.1+](https://img.shields.io/badge/ruby-%3E%3D%203.1-cc342d)

**Ruby client for EVM smart contracts, inspired by [viem](https://viem.sh).**
Declare a contract class from its ABI and every function becomes a Ruby method. Wallets sign EIP-1559
transactions, connectors (Alchemy first) speak JSON-RPC, and polling helpers wait for receipts, blocks and
events with resumable cursors.

```ruby
BlockGiven.configure do |c|
  c.connector = BlockGiven::Connectors::Alchemy.new(api_key: ENV["ALCHEMY_API_KEY"])
  c.chain = :base
end

class Usdc < BlockGiven::Contract
  abi_file "abis/erc20.json"   # ABIs live in your repo, not in the gem
  address "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
end

wallet = BlockGiven::Wallet.new(private_key: ENV["PRIVATE_KEY"])
usdc = Usdc.new(wallet: wallet)

usdc.balance_of(wallet.address)                 # => 12_500_000  (eth_call, decoded)
tx = usdc.transfer(to: "0x7099...79C8", amount: 1e6)  # signs + broadcasts, returns BlockGiven::Transaction
receipt = tx.wait!                              # polls until mined, raises if reverted
usdc.events_from(receipt)                       # => [#<BlockGiven::Event Transfer {from:, to:, value: 1000000}>]
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
gem "block_given"
```

BlockGiven depends on the [`eth`](https://github.com/q9f/eth.rb) gem for secp256k1, keccak and ABI primitives.
Its native extension needs libsecp256k1; on macOS `brew install secp256k1` then
`gem install rbsecp256k1 -- --with-system-library` if the bundled build fails.

Requires Ruby >= 3.1.

## Configuration

```ruby
BlockGiven.configure do |c|
  c.connector = BlockGiven::Connectors::Alchemy.new(api_key: ENV["ALCHEMY_API_KEY"])
  c.chain = :base               # BlockGiven::Chains::BASE, "base-sepolia", 8453 ... all work
  c.polling_interval = 2.0      # seconds between polls (receipts, blocks, events)
  c.timeout = 180               # seconds before Transaction#wait gives up
  c.confirmations = 1           # blocks to wait for in Transaction#wait
  c.gas_multiplier = 1.2        # margin applied to eth_estimateGas
  c.base_fee_multiplier = 1.2   # maxFeePerGas = baseFee * 1.2 + priorityFee (viem default)
  c.abi_path = "abis"           # optional: directory Contract.abi_file resolves relative paths against
  c.logger = Logger.new($stdout, level: Logger::DEBUG)  # logs every JSON-RPC call at DEBUG
end

BlockGiven.client   # default BlockGiven::Client built from the config
```

### Connectors

| Connector                                 | Usage                                                                                                   |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `BlockGiven::Connectors::Alchemy.new(api_key:)` | Endpoint derived from the chain (`base-mainnet.g.alchemy.com`, ...). One instance serves every network. |
| `BlockGiven::Connectors::Http.new(url:)`        | Any JSON-RPC endpoint (Hardhat, Anvil, Infura...). Without `url:` it uses the chain's public RPC.       |
| `BlockGiven::Connectors::Stub.new(...)`         | In-memory responses for tests (see below).                                                              |

All HTTP connectors retry on 429/5xx/timeouts with exponential backoff (`retries:`, `retry_delay:`),
support `batch`, and never print API keys in `inspect`.

### Chains

Built in: `MAINNET`, `SEPOLIA`, `BASE`, `BASE_SEPOLIA`, `POLYGON`, `POLYGON_AMOY`, `ARBITRUM`,
`ARBITRUM_SEPOLIA`, `OPTIMISM`, `OPTIMISM_SEPOLIA`, `LOCALHOST` (31337). Custom:

```ruby
fork = BlockGiven::Chain.new(id: 31_337, name: "Base fork", rpc_urls: ["http://127.0.0.1:8545"])
client = BlockGiven::Client.new(chain: fork, connector: BlockGiven::Connectors::Http.new)
```

## Contracts

The gem ships no ABI: keep them in your repository (`abis/*.json`, or the Hardhat/Foundry artifacts) and
point each contract class at its file. With `BlockGiven.config.abi_path = Rails.root.join("abis")` relative
names resolve from that directory.

```ruby
class Usdc < BlockGiven::Contract
  abi_file "erc20.json"                              # ABI array, Hardhat/Foundry artifact ({ "abi": [...] }), or JSON string via `abi`
  address "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" # optional default address (USDC on Base)
  chain :base                                        # optional: pins the chain regardless of the global config
end

usdc = Usdc.new(wallet: wallet)                                          # default address
usdc = Usdc.at("0x036CbD53842c5426634e7929541eC2318f3dCF7e", wallet: wallet)  # explicit address (USDC on Base Sepolia)
usdc = Usdc.at("0x036CbD53842c5426634e7929541eC2318f3dCF7e")                 # read-only (no wallet)
```

### Calling functions

Every ABI function is available in snake_case. `view`/`pure` functions run `eth_call` and return decoded
values; the others sign and broadcast a transaction and return a `BlockGiven::Transaction`.

```ruby
usdc.balance_of("0x...")                      # positional
usdc.balance_of(account: "0x...")             # keyword (ABI input names, leading _ stripped, snake_cased)
usdc.transfer(to: "0x...", amount: 1e6)       # 1 USDC; floats are accepted when they are whole numbers
usdc.transfer(wallet2, 1_000_000)             # anything responding to #address works as an address
usdc.approve(spender, 2**256 - 1)             # uint256 takes any Integer
usdc.allowance(wallet.address, spender)
```

Argument coercion: integers accept `Integer`, whole `Float`/`BigDecimal`, decimal or hex strings; tuples accept
`Hash` (component names) or `Array`; `bytes` accept hex or binary strings. Decoded outputs give checksummed
addresses, `0x` hex for bytes, and named tuples as `Hash`. Multiple outputs come back as an `Array`.

Transaction and call overrides live in the reserved `tx:` keyword so they never clash with ABI input names
(ERC20 itself has an input called `value`):

```ruby
usdc.transfer(to: addr, amount: 1e6, tx: { gas: 80_000, nonce: 12 })
usdc.balance_of(addr, tx: { block: 20_000_000 })                # historical read
weth.deposit(tx: { value: BlockGiven::Utils.parse_ether("0.1") })  # payable: weth = Weth.at("0x4200000000000000000000000000000000000006")
usdc.simulate(:transfer, addr, 1e6, tx: { from: treasury })     # eth_call with another msg.sender
# allowed keys: value gas nonce max_fee_per_gas max_priority_fee_per_gas gas_price from block
```

Explicit API (handles names clashing with Ruby methods, overloads by signature, etc.):

```ruby
usdc.read(:balance_of, addr)
usdc.write("transfer(address,uint256)", addr, 1_000_000)   # full signature picks an overload
usdc.simulate(:transfer, addr, 10**12)     # eth_call from the wallet: raises the decoded revert without paying gas
usdc.estimate_gas(:transfer, addr, 1_000_000)
usdc.encode_function_data(:transfer, to: addr, amount: 1)
usdc.decode_function_result(:balance_of, "0x...")
```

### Transactions & receipts

```ruby
tx = usdc.transfer(to: addr, amount: 1e6)
tx.hash                      # "0x..."
tx.explorer_url              # https://basescan.org/tx/0x...
tx.mined?                    # non-blocking
receipt = tx.wait(confirmations: 2, timeout: 300, polling_interval: 1)
receipt.status               # :success / :reverted
receipt.gas_used, receipt.fee, receipt.block_number, receipt.logs
tx.wait!                     # raises BlockGiven::TransactionRevertedError when status is :reverted
tx.status                    # :success / :reverted (mined), :pending (in the mempool), :unknown (never seen or dropped)
tx.confirmations             # blocks since inclusion (non-blocking), tx.confirmed?(5)
client.transaction("0x...")  # the same handle for a hash you persisted earlier
```

### Reliable writes: sign first, broadcast later

A transaction hash is the keccak of the signed bytes, so it is known **before** anything is sent.
`prepare_write` (or `Wallet#signed_transaction`) signs without broadcasting; persist the hash and
nonce, then broadcast. If the RPC call times out you still know exactly which transaction to look for,
and a same-nonce replacement can never be mined twice. Example: paying out USDC from an outbox table.

```ruby
signed = usdc.prepare_write(:transfer, to: payout.wallet, amount: 12_500_000, tx: { nonce: payout.nonce })
signed.hash, signed.nonce, signed.raw                       # known now; signed.to_h for persistence
payout.update!(tx_hash: signed.hash, raw_tx: signed.raw, status: :submitted)
signed.broadcast                                            # eth_sendRawTransaction, returns the Transaction

# later, one tick of your outbox worker (possibly another process: rebuild from the persisted bytes)
signed = BlockGiven::SignedTransaction.from_raw(payout.raw_tx, wallet: wallet, interface: usdc.interface)
tx = signed.transaction                                     # same as client.transaction(payout.tx_hash)
case tx.status
when :success  then payout.confirmed! if tx.confirmed?(5)   # usdc.events_from(tx.receipt) => [Transfer ...]
when :reverted then payout.failed!
when :unknown  then signed.broadcast                        # dropped by the node: resend the same bytes
when :pending  then signed.replacement.broadcast if payout.submitted_at < 5.minutes.ago
end
```

`replacement(fee_multiplier: 1.125)` re-signs the same payload and nonce with fees raised by the
multiplier (at least 10%, otherwise nodes reject it as underpriced) and never below a fresh estimate. If
the original gets mined first, the replacement is rejected for its nonce and `tx.status` tells you so.

### Reverts

`eth_call`, `eth_estimateGas` and sends that revert raise `BlockGiven::ContractRevertError`.
`Error(string)` and `Panic(uint256)` reasons are decoded; custom errors are decoded with the contract ABI:

```ruby
begin
  usdc.transfer(to: addr, amount: 10**12)
rescue BlockGiven::ContractRevertError => e
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

`BlockGiven::Event` exposes `name`, `args` (snake_case symbols, declaration order), `[]`, `address`, `block_number`,
`transaction_hash`, `log_index`. Indexed `string`/`bytes`/arrays only carry their keccak hash, as on-chain.

## Polling

```ruby
client = BlockGiven.client

client.watch_block_number(emit_missed: true) { |n| ... }     # BlockGiven::Watcher
client.watch_blocks { |block| ... }
client.watch_logs(address: addr, topics: [...]) { |logs| ... }
client.wait_for_transaction_receipt(hash, confirmations: 3)
client.get_logs_in_chunks(address: addr, from_block: 1, to_block: :latest)   # splits by max_block_range

# generic blocking poll: returns the first truthy value or raises BlockGiven::TimeoutError
BlockGiven::Poller.poll(interval: 1, timeout: 60) { client.get_transaction_receipt(hash) }
```

### Listing, stopping and killing watchers

Every running watcher is registered under a unique id (auto-generated, or the `id:` you pass), and its
thread is named `block_given:<id>` so it shows up in `Thread.list` and in thread dumps.

```ruby
usdc.watch_event(:Transfer, id: "usdc-deposits") { |e| ... }
BlockGiven.client.watch_block_number { |n| ... }               # id auto-generated: "block_number-3fa9c1"

BlockGiven.watchers                          # => running watchers, oldest first (alias BlockGiven::Watcher.all)
BlockGiven.watchers.map(&:to_h)              # id, name, status, cursor, ticks, started_at, last_tick_at, last_error...
BlockGiven::Watcher.find("usdc-deposits")    # => the watcher, nil if not running
BlockGiven::Watcher.stop("usdc-deposits", join: 5)   # graceful: finishes the current tick
BlockGiven::Watcher.kill("usdc-deposits")            # forceful: Thread#kill, for a tick stuck in a network call
BlockGiven::Watcher.stop_all(join: 5)                # e.g. in an at_exit / SIGTERM handler
```

Starting a second watcher with an id that is already running raises, which protects against double
starts after a code reload. `BlockGiven.reset!` stops every watcher.

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
    cursor = IndexerCursor.find_or_create_by!(name: "usdc_deposits") { |c| c.block = BlockGiven.client.block_number }
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
wallet = BlockGiven::Wallet.new(private_key: ENV["PRIVATE_KEY"])   # with or without 0x
BlockGiven::Wallet.generate
wallet.address, wallet.balance, wallet.nonce
wallet.sign_message("hello")                # EIP-191
wallet.sign_typed_data(typed_data)          # EIP-712
wallet.send_transaction(to: addr, value: BlockGiven::Utils.parse_ether("0.01")).wait
wallet.send_transaction(to: addr, data: "0x...", gas_price: BlockGiven::Utils.parse_gwei("2"))  # legacy type-0 tx
wallet.prepare_transaction(to: addr, data: "0x...")   # resolved nonce/gas/fees without signing
wallet.signed_transaction(to: addr, data: "0x...")    # signed, not broadcast: #hash, #nonce, #broadcast, #replacement
```

Missing fields are filled from the client: pending nonce, `eth_estimateGas * gas_multiplier`,
EIP-1559 fees from the latest block's base fee and `eth_maxPriorityFeePerGas`.

## Client (low level)

`BlockGiven::Client` mirrors viem's public client: `chain_id`, `block_number`, `get_block`, `get_balance`,
`get_transaction_count`, `get_code`, `get_storage_at`, `call`, `estimate_gas`, `gas_price`,
`estimate_fees_per_gas`, `send_raw_transaction`, `get_transaction`, `get_transaction_receipt`, `get_logs`,
plus `request(method, *params)` and `batch([[method, params], ...])` for anything else. Results use
snake_case symbol keys with integer quantities.

## Utils

```ruby
BlockGiven::Utils.parse_units("1.5", 6)      # => 1_500_000
BlockGiven::Utils.format_units(1_500_000, 6) # => "1.5"
BlockGiven::Utils.parse_ether("0.1"), BlockGiven::Utils.format_ether(wei), parse_gwei, format_gwei
BlockGiven::Utils.keccak256("transfer(address,uint256)")  # => "0xa9059cbb..."
BlockGiven::Utils.checksum_address(addr), BlockGiven::Utils.address?(str), BlockGiven::Utils.to_hex(255), hex_to_int("0xff")
```

Token helpers are one method away in your own contract class:

```ruby
class Erc20 < BlockGiven::Contract
  abi_file "erc20.json"
  def decimals = @decimals ||= read(:decimals)
  def parse_amount(value) = BlockGiven::Utils.parse_units(value, decimals)    # "1.5" -> 1_500_000
  def format_amount(value) = BlockGiven::Utils.format_units(value, decimals)  # 1_500_000 -> "1.5"
end
```

## Testing your code

`BlockGiven::Connectors::Stub` answers JSON-RPC calls from memory:

```ruby
stub = BlockGiven::Connectors::Stub.new(
  "eth_call" => "0x" + "1".rjust(64, "0"),
  "eth_blockNumber" => BlockGiven::Connectors::Stub.sequence("0x10", "0x11"),   # consumed in order
  "eth_getTransactionReceipt" => ->(params) { receipts[params.first] }
)
BlockGiven.configure { |c| c.connector = stub; c.chain = :base; c.polling_interval = 0 }
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

BlockGiven has no runtime dependency on Rails or ActiveSupport: it is plain Ruby and works in scripts,
Sidekiq workers, Rails apps or Hanami alike.

### Rails integration

```ruby
# config/initializers/block_given.rb
BlockGiven.configure do |c|
  c.connector = BlockGiven::Connectors::Alchemy.new(api_key: Rails.application.credentials.alchemy_api_key)
  c.chain = Rails.env.production? ? :base : :base_sepolia
  c.abi_path = Rails.root.join("abis")
end
```

A railtie (loaded automatically when Rails is present) routes BlockGiven's logs to `Rails.logger`
unless the initializer sets `c.logger` itself. Contract classes live wherever you want
(`app/contracts/usdc.rb` works with Zeitwerk out of the box) and ABI files in `abis/`.

## Development

```bash
bin/setup                            # bundle install (+ libsecp256k1 fallback)
bundle exec rspec                    # unit suite (Stub connector, no network)
COVERAGE=1 bundle exec rspec         # + SimpleCov report in coverage/ (minimum 90% lines)
bundle exec rubocop
ALCHEMY_API_KEY=... bin/console      # IRB with BlockGiven configured for BLOCK_GIVEN_CHAIN (default base)

bundle exec rake ci                  # specs + rubocop + gem build

# Ruby / Rails matrix (Docker for the Rubies you do not have locally)
bin/matrix                           # Ruby 3.2, 3.3, 3.4
bin/matrix rails 7.2                 # Rails 7.2 compat suite, local Ruby
bin/matrix rails 8.0 3.4             # Rails 8.0 under Ruby 3.4
```

CI runs the suite on Ruby 3.1 to 3.4 and against Rails 7.0, 7.1, 7.2 and 8.0 (`.github/workflows/ci.yml`).

### Versioning & releases

BlockGiven follows [Semantic Versioning](https://semver.org): breaking changes to the public API
(`BlockGiven::Contract`, `Wallet`, `Client`, connectors, `Utils`) bump the major version, additions the minor,
fixes the patch. Every change is listed in `CHANGELOG.md`. Dependency policy: Ruby versions are dropped
only once they reach end of life, Rails versions are tested while they receive security fixes, and the `eth`
constraint is only tightened when a feature needs it.

To release: bump `lib/block_given/version.rb`, move the `Unreleased` notes under the new version in `CHANGELOG.md`,
commit, then push a `vX.Y.Z` tag. The release workflow checks the tag against the version, runs the suite and
publishes through RubyGems trusted publishing (no API key in CI). `bundle exec rake release` does the same
from a maintainer machine with RubyGems credentials.

## Security

- Private keys never leave `BlockGiven::Wallet`; `inspect` hides them and API keys are masked in every log and
  error message (`Http#redact`).
- Never commit keys: use `ENV`, Rails credentials or Hardhat vars, and keep `.env` out of git (see `.env.example`).
- Report a vulnerability privately to remi@boleromusic.com rather than in a public issue. See [SECURITY.md](SECURITY.md).

## Contributing

Bug reports and pull requests are welcome on [GitHub](https://github.com/Bolero-Music/block_given). Please read
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
