---
name: debug-rpc
description: Investigate a failing contract call, transaction, or event fetch (revert reasons, wrong encoding, provider limits, rate limits, unexpected nil). Use when a UncleBlockGiven user reports "it does not work against the node".
---

# Debug an RPC problem

## 1. See the wire

```ruby
UncleBlockGiven.config.logger = Logger.new($stdout, level: Logger::DEBUG)   # logs every method + params + result
```
Keys are masked; the debug log is safe to paste. Compare `data` against `contract.encode_function_data(...)`.

## 2. Reproduce offline

Copy the real response into a `UncleBlockGiven::Connectors::Stub` and write the failing spec first. Stub values:
static, `Stub.sequence(a, b)` for successive polls, `->(params) { ... }` for param-dependent answers,
an exception instance to raise.

## 3. Common causes

| Symptom | Likely cause | Where |
|---|---|---|
| `AbiError: cannot decode empty data` | wrong address / no contract on this chain, or wrong chain configured | `client.contract?(address)`, `client.chain` |
| `ContractRevertError` with no reason | provider omits revert data on `eth_estimateGas`; run `contract.simulate` to get `eth_call` data | `RpcError.extract_revert_data` |
| custom error not named | selector unknown to the ABI (outdated artifact) | `interface.error_by_selector` |
| `RpcError` about block range / log limit on `get_events` | provider caps `eth_getLogs`; pass `max_block_range:` or lower it in config | `Client#get_logs_in_chunks` |
| `HttpError` 429 after retries | rate limit; raise `polling_interval`, lower watcher count, check `UncleBlockGiven.watchers` for duplicates | connector `retries`/`retry_delay` |
| `nonce too low` / `replacement transaction underpriced` | concurrent sends from one wallet; serialize or pass `tx: { nonce: }` | `Wallet#prepare_transaction` |
| `TimeoutError` on `wait` | tx stuck (fees too low) or wrong chain; check `tx.details` and `explorer_url` | `Client#wait_for_transaction_receipt` |
| `Eth::Tx::ParameterError: gas limit too low` | explicit `gas:` below intrinsic cost | `Wallet#sign_transaction` |

## 4. Live read-only check (console only)

```ruby
UncleBlockGiven.configure { |c| c.connector = UncleBlockGiven::Connectors::Http.new; c.chain = :base }   # public RPC, no key
UncleBlockGiven.client.block_number
```
Never commit a script with a real key, and never send transactions from a debugging session without the
maintainer's explicit go.
