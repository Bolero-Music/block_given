# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to
[Semantic Versioning](https://semver.org).

## [Unreleased]

## [0.2.0] - 2026-10-09

### Added

- `BlockGiven::Abi::Standards`: the ERC20, ERC721, ERC1155 and ERC4626 interfaces ship as frozen ABI arrays (EIP
  functions and events, metadata / ERC-165 / enumerable extensions, ERC-6093 custom errors), with the input names of
  OpenZeppelin 5 (`transfer(to:, value:)`). `Contract.abi` accepts their Symbol name (`abi :erc20`),
  `Abi::Standards.fetch("ERC-721")` returns the array, `Abi::Standards.names` lists them.

### Changed

- **The `eth` gem is no longer a dependency**, and with it the unmaintained `rbsecp256k1` native extension, which
  failed to compile on Debian bullseye (system libsecp256k1 too old, broken bundled download). Keccak-256,
  secp256k1 (RFC 6979 deterministic signatures, low-s, recovery), RLP, EIP-1559 / legacy EIP-155 transactions,
  EIP-191, EIP-712 and the ABI codec are now implemented in the gem on top of Ruby's OpenSSL standard library. The
  gem installs with no native extension and no system package. Keys, signatures, raw transactions, hashes and ABI
  encodings are byte-identical to what `eth` 0.5.17 produced (golden vectors in `spec/fixtures/`).
- EIP-712: arrays are now hashed as the specification defines them (as viem and on-chain verifiers do); `eth`
  encoded them as inline ABI arrays and rejected arrays of structs. `sign_typed_data` also accepts String keys and
  a payload without an `EIP712Domain` type (derived from the domain, like viem).
- Errors that used to leak from `eth` are typed: invalid transaction fields (negative values, gas limit below the
  intrinsic gas) and out-of-range private keys raise `InvalidArgumentError`; ABI failures raise the new
  `AbiEncodingError` / `AbiDecodingError` (both `AbiError`, same messages); unsupported ABI types (`fixed`,
  `function`) raise `AbiError`.
- `SignedTransaction.from_raw` returns a non-empty access list as `[{ address:, storage_keys: }]` (it returned raw
  RLP bytes), and transactions accept access lists in that form as documented.
- ABI: a `string` argument that looks like hex (`"0x12"`) is encoded as text (it was encoded as bytes), and decoded
  `bytes` values are always `0x` hex.
- YARD documentation for the whole public API (every method, option, block and return value), published on
  [rubydoc.info](https://rubydoc.info/gems/block_given); `rake doc` builds it locally and `rake doc_check` (part of
  `rake ci` and GitHub CI) fails under 100% coverage.

## [0.1.0] - 2026-09-11

Initial release.

- `BlockGiven::Contract`: typed contract classes from an ABI file (`abi_file`, `BlockGiven.config.abi_path`), snake_case
  methods for every function, positional or keyword arguments, `tx:` overrides, `read` / `write` / `simulate` /
  `estimate_gas`, overload resolution by arity, keyword names or full signature.
- `BlockGiven::Wallet`: EIP-1559 and legacy signing, EIP-191 / EIP-712, automatic nonce, gas and fee resolution.
- `BlockGiven::Client`: JSON-RPC client (blocks, balances, calls, receipts, logs), EIP-1559 fee estimation,
  `wait_for_transaction_receipt`, `get_logs_in_chunks`.
- `BlockGiven::SignedTransaction` (`Contract#prepare_write`, `Wallet#signed_transaction`): sign without
  broadcasting, hash and nonce known before any network call, `broadcast`, `replacement(fee_multiplier:)` for
  same-nonce fee bumps, `.from_raw` to rebuild one from persisted bytes. `Transaction#hash` is computed locally
  from the signed bytes (a differing node answer is logged). `Transaction#status` (`:success` / `:reverted` /
  `:pending` / `:unknown`), `#confirmations`, `#confirmed?`, `#reload` for non-blocking outbox workers.
- Connectors: Alchemy (endpoint derived from the chain), generic HTTP with retries and backoff, in-memory Stub
  for tests. Secrets are masked in `inspect`, logs and error messages.
- Events: `get_events` with indexed filters, `watch_event` polling with chunked catch-up (`from_block`,
  `max_block_range`), reorg margin (`confirmations`), `on_progress` cursor callback.
- Watcher registry: unique ids, `BlockGiven.watchers`, `BlockGiven::Watcher.find / stop / kill / stop_all`, named threads,
  diagnostics (`to_h`).
- Revert decoding: `Error(string)`, `Panic(uint256)` and custom errors from the contract ABI.
- Chains: Ethereum, Sepolia, Base, Base Sepolia, Polygon, Amoy, Arbitrum, Optimism (+ Sepolias), Localhost.
- Optional Rails railtie (Rails 7.0 to 8.0) routing logs to `Rails.logger`.
- Supported Ruby 3.1 to 3.4.

[Unreleased]: https://github.com/Bolero-Music/block_given/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/Bolero-Music/block_given/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Bolero-Music/block_given/releases/tag/v0.1.0
