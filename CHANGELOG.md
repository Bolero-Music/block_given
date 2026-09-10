# Changelog

## [Unreleased]

## [0.1.0] - 2026-09-10

- Supported: Ruby 3.1 to 3.4; Rails 7.0 to 8.0 (optional railtie routing logs to `Rails.logger`).
- Initial release: typed contracts from ABI (`Vium::Contract`), `Vium::Wallet` (EIP-1559 / legacy
  signing, EIP-191 & EIP-712), `Vium::Client` (JSON-RPC, fee estimation, receipts, logs),
  Alchemy / HTTP / Stub connectors, polling helpers (`wait`, `watch_block_number`, `watch_event`),
  revert & custom error decoding, built-in `Vium::ERC20`.
