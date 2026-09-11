---
name: add-client-method
description: Add or change a JSON-RPC method on BlockGiven::Client (eth_* wrappers, fee logic, receipts, logs). Use when exposing a new RPC call or changing what an existing client method returns.
---

# Add a Client method

`BlockGiven::Client` wraps JSON-RPC so callers get Ruby values. Follow the existing methods in `lib/block_given/client.rb`.

## Steps

1. **Name it like viem**, snake_cased: `eth_getBalance` → `get_balance`, `eth_feeHistory` → `get_fee_history`.
   Keyword args for options, `block: :latest` when the RPC takes a block parameter.
2. **Convert inputs**: addresses through `Utils.checksum_address`, quantities through `Utils.to_hex`, block
   tags/numbers through `Utils.block_tag`. Never pass raw user strings.
3. **Convert outputs**: hex quantities with `Utils.hex_to_int`; objects (blocks, txs, receipts, logs) with
   `Normalizer.normalize` (snake_case symbol keys, Integer quantities). Wrap in `Receipt` / `Transaction`
   when a value object exists. `nil` results stay `nil` (not found), never raise.
4. **Errors**: let `RpcError` / `ContractRevertError` propagate. If a method is optional on some nodes
   (like `eth_maxPriorityFeePerGas`), rescue `RpcError` and fall back explicitly with a comment.
5. **Spec** in `spec/block_given/client_spec.rb` with `build_stub` (see `spec_helper.rb`): assert both the params
   sent (`stub.calls_for("eth_x").last`) and the decoded result. No network.
6. **Docs**: one line in README "Client (low level)" and CHANGELOG `Unreleased`.

## Example

```ruby
def get_fee_history(block_count, newest_block: :latest, reward_percentiles: [])
  raw = request("eth_feeHistory", Utils.to_hex(block_count), Utils.block_tag(newest_block), reward_percentiles)
  Normalizer.normalize(raw)
end
```

If `Normalizer::QUANTITY_KEYS` lacks a field the response returns as hex, add it there (with a spec).
