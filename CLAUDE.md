# CLAUDE.md — uncle_block_given

Ruby gem: viem-inspired client for EVM smart contracts (typed contracts from ABI, wallet signing, JSON-RPC
connectors, polling with resumable cursors). Used by Bolero Music's Rails API to talk to contracts on Base.
Public API and behaviour are documented in `README.md`; this file is about how we work on the code.

## Commands

```bash
bin/setup                       # bundle install (+ libsecp256k1 fallback)
bundle exec rspec               # unit suite, no network (Stub connector + WebMock)
bundle exec rubocop             # must be clean; rubocop -a fixes most style issues
bundle exec rake ci             # rspec + rubocop + gem build — run before every commit
COVERAGE=1 bundle exec rspec    # SimpleCov, 90% line minimum enforced
bin/matrix                      # Ruby 3.2/3.3/3.4 in Docker; bin/matrix rails 7.2 for the Rails suite
ALCHEMY_API_KEY=... bin/console # IRB with UncleBlockGiven configured (UNCLE_BLOCK_GIVEN_CHAIN, UNCLE_BLOCK_GIVEN_ABI_PATH)
```

## Layout

| Path | Role |
|---|---|
| `lib/uncle_block_given.rb` | requires, `UncleBlockGiven.configure / config / client / watchers / reset!` |
| `lib/uncle_block_given/configuration.rb` | global defaults (polling interval, timeout, multipliers, abi_path, logger) |
| `lib/uncle_block_given/chain.rb` | `Chain` struct + `Chains` constants and `resolve` |
| `lib/uncle_block_given/connectors/` | `Base` (interface), `Http` (Net::HTTP, retries, `redact`), `Alchemy`, `Stub` (tests) |
| `lib/uncle_block_given/client.rb` | JSON-RPC methods, fee estimation, receipts, logs, `watch_*` |
| `lib/uncle_block_given/poller.rb` | `Poller.poll` (blocking) and `Watcher` (thread + registry by id) |
| `lib/uncle_block_given/wallet.rb` | key, signing (EIP-1559/legacy/191/712), tx preparation |
| `lib/uncle_block_given/transaction.rb`, `receipt.rb`, `event.rb`, `normalizer.rb` | value objects around RPC results |
| `lib/uncle_block_given/abi/` | `Interface` (parse, overloads), `Function`, `Event`, `CustomError`, `Parameter`, `Coder` (coercion) |
| `lib/uncle_block_given/contract.rb` | class-level DSL (`abi`, `abi_file`, `address`, `chain`) + read/write/simulate/events |
| `lib/uncle_block_given/railtie.rb` | optional, loaded when `Rails::Railtie` is defined |
| `spec/` | mirrors `lib/`; `spec/fixtures/erc20.json` is the only ABI in the repo |
| `gemfiles/` | Rails 7.0–8.0 compat Gemfiles (`RAILS_COMPAT=1`) |

## Rules we follow

- **No network in specs.** RPC via `UncleBlockGiven::Connectors::Stub` (`Stub.sequence` for successive answers, procs for
  param-dependent ones), HTTP layer via WebMock. Live read-only checks against a public RPC are fine in a
  console, never committed as specs.
- **Secrets never reach output.** Keys are masked in `inspect`, logs and exception messages (`Http#redact`,
  `Wallet#inspect`). Any new code path that can print an endpoint, a key or a raw config must have a spec
  asserting the secret is absent.
- **`tx:` is the only reserved keyword on contract methods.** Everything else maps to ABI input names.
  Never add top-level keywords like `value:` or `from:` to dynamic methods (ERC20 has an input named `value`).
- **No ABI in the gem.** Applications own their ABIs (`abi_file`, `UncleBlockGiven.config.abi_path`).
- **Ruby 3.1 is the floor.** No syntax newer than 3.1. Known trap: anonymous block `&` combined with keyword
  arguments is a syntax error on 3.1, name the block param. Endless methods (`def x = ...`) are fine.
- **Return Ruby values, not hex.** Client methods decode QUANTITY to Integer, normalize keys to snake_case
  symbols (`Normalizer`), checksum addresses, hex-encode bytes.
- **Errors are typed.** Raise `UncleBlockGiven::*` errors (`errors.rb`); wrap third-party exceptions (`Eth::Abi::*`,
  `Net::*`) at the boundary. Revert data becomes `ContractRevertError` and is enriched with the contract ABI.
- **Watchers must be stoppable and resumable.** Any new `watch_*` goes through `Client#watcher` (registry, id,
  named thread), keeps only a cursor across ticks, and never advances the cursor before the block ran.
- **Every user-visible change**: CHANGELOG line under `Unreleased`, README update when the API changes, specs.
- **Semver.** Breaking changes to `Contract`, `Wallet`, `Client`, connectors, `Utils` bump the major.
- Commits: imperative summary under 72 chars, blank line, the why. Branch from `main`.

## Skills

Task-specific playbooks live in `.claude/skills/`: `add-client-method`, `add-connector`, `add-chain`,
`contract-dsl`, `test-matrix`, `release`, `debug-rpc`. Use `.claude/agents/gem-reviewer.md` for a pre-PR review.

## Context

- Bolero contracts: `catalog-shares` (ERC20 catalog shares, Base) and `smart-contracts` (ERC1155 SongShares).
  Their Hardhat artifacts are the ABIs applications will feed to `abi_file`.
- Today the Nest.js blockchain service watches on-chain events; uncle_block_given's watchers + app-side cursor are the
  intended Ruby replacement (see README "How watchers behave").
- Provider: Alchemy. `eth_getLogs` ranges are capped by the provider, hence `max_block_range` (default 2000).
