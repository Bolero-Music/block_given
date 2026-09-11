---
name: contract-dsl
description: Change how Vium::Contract or the ABI layer behaves (argument coercion, output formatting, overloads, tx: options, events, revert decoding). Use before editing lib/vium/contract.rb or lib/vium/abi.
---

# Contract DSL and ABI layer

## Invariants

- Dynamic methods are defined once per ABI function name in `Contract.define_abi_methods!`. Signature is
  always `(*args, tx: {}, **kwargs)`: positional OR keyword ABI inputs, `tx:` for overrides. Adding any other
  reserved keyword breaks contracts whose inputs share that name (`value`, `from`, `to` are common inputs).
- Allowed `tx:` keys are `Contract::TX_OPTIONS`; unknown keys raise `InvalidArgumentError`.
- Names clashing with existing methods (`send`, `class`, `address`…) are skipped; `read`/`write` remain
  available. Never `define_method` over a Ruby core method.
- Keyword names are matched after `Utils.snake_case` (strips leading `_`, camelCase → snake). Unnamed ABI
  inputs are positional only.
- Overloads: resolved by arity (positional), by keyword set (kwargs), or by full signature
  `"safeMint(address,bytes)"`. Ambiguity raises `AmbiguousFunctionError` listing the signatures.

## Coercion (`Abi::Coder`)

Inputs: Integer types accept Integer, whole Float/BigDecimal, decimal or hex String (fractional → error
pointing at `parse_units`); addresses accept anything responding to `#address`; tuples accept Hash (component
names, any case) or Array; bytes accept hex or binary. Outputs: addresses checksummed, bytes as `0x` hex,
named tuples as Hash with snake_case symbol keys, single output unwrapped, several as Array.

When adding a type rule, add cases to `spec/vium/abi/interface_spec.rb` (encode + decode round trip through
`Eth::Abi` in `abi_encode`).

## Events

`Abi::Event#decode(log)` → `Vium::Event` with args in declaration order; indexed dynamic types keep the
topic hash. `encode_topics(args)` builds the filter (nil wildcard, Array = OR, trailing nils trimmed).

## Reverts

`RpcError.from_payload` extracts revert data (`data` or nested `data.data`), builds `ContractRevertError`
with `Error(string)` / `Panic` decoding. Contract methods wrap RPC calls in `with_decoded_errors` which calls
`decode_with(interface)` to name custom errors. Keep that wrapper around any new RPC call in `Contract`.

## Testing

Use `TestERC20` from `spec_helper.rb` (fixture ABI). For new ABI shapes, add an inline ABI Array in the spec
rather than a new fixture file.
