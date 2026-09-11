# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to
[Semantic Versioning](https://semver.org).

## [Unreleased]

## [0.1.0] - unreleased

Initial release.

- `Vium::Contract`: typed contract classes from an ABI file (`abi_file`, `Vium.config.abi_path`), snake_case
  methods for every function, positional or keyword arguments, `tx:` overrides, `read` / `write` / `simulate` /
  `estimate_gas`, overload resolution by arity, keyword names or full signature.
- `Vium::Wallet`: EIP-1559 and legacy signing, EIP-191 / EIP-712, automatic nonce, gas and fee resolution.
- `Vium::Client`: JSON-RPC client (blocks, balances, calls, receipts, logs), EIP-1559 fee estimation,
  `wait_for_transaction_receipt`, `get_logs_in_chunks`.
- Connectors: Alchemy (endpoint derived from the chain), generic HTTP with retries and backoff, in-memory Stub
  for tests. Secrets are masked in `inspect`, logs and error messages.
- Events: `get_events` with indexed filters, `watch_event` polling with chunked catch-up (`from_block`,
  `max_block_range`), reorg margin (`confirmations`), `on_progress` cursor callback.
- Watcher registry: unique ids, `Vium.watchers`, `Vium::Watcher.find / stop / kill / stop_all`, named threads,
  diagnostics (`to_h`).
- Revert decoding: `Error(string)`, `Panic(uint256)` and custom errors from the contract ABI.
- Chains: Ethereum, Sepolia, Base, Base Sepolia, Polygon, Amoy, Arbitrum, Optimism (+ Sepolias), Localhost.
- Optional Rails railtie (Rails 7.0 to 8.0) routing logs to `Rails.logger`.
- Supported Ruby 3.1 to 3.4.

[Unreleased]: https://github.com/Bolero-Music/vium/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Bolero-Music/vium/releases/tag/v0.1.0
