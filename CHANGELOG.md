# Changelog

## [Unreleased]

- Watcher registry: unique `id:` per watcher, `Vium.watchers`, `Vium::Watcher.find/stop/kill/stop_all`,
  named threads (`vium:<id>`), `Watcher#to_h` diagnostics (status, cursor, ticks, last_error).
- Log/event watchers: chunked catch-up from `from_block` (`max_block_range`), `confirmations:` lag,
  `on_progress` callback and `Watcher#cursor` for app-side persistence; `Client#get_logs_in_chunks`.

## [0.1.0] - 2026-09-10

- Supported: Ruby 3.1 to 3.4; Rails 7.0 to 8.0 (optional railtie routing logs to `Rails.logger`).
- Initial release: typed contracts from ABI (`Vium::Contract`), `Vium::Wallet` (EIP-1559 / legacy
  signing, EIP-191 & EIP-712), `Vium::Client` (JSON-RPC, fee estimation, receipts, logs),
  Alchemy / HTTP / Stub connectors, polling helpers (`wait`, `watch_block_number`, `watch_event`),
  revert & custom error decoding. ABIs are loaded from the application (`abi_file`, `Vium.config.abi_path`); the gem ships none.
