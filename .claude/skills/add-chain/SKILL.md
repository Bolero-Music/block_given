---
name: add-chain
description: Register a new EVM network in UncleBlockGiven::Chains (id, RPC url, explorer, Alchemy slug) or fix an existing chain definition.
---

# Add a chain

Chains are constants in `lib/uncle_block_given/chain.rb`, resolved by `Chains.resolve(:symbol | "network-slug" | id)`.

1. Add a `Chain.new(...)` constant with: `id` (chain id), `name`, `network` (kebab-case slug used by
   `resolve`), `native_currency` if not ETH, `rpc_urls` (one public HTTPS endpoint for the no-key `Http`
   connector), `block_explorer_url` (no trailing slash), `alchemy_network` (Alchemy subdomain, `nil` if
   unsupported), `testnet: true` for testnets.
2. Append it to `ALL` (order: mainnet then its testnets, keep families together).
3. Verify the chain id and Alchemy slug against the provider docs; do not guess.
4. Spec in `spec/uncle_block_given/chains_spec.rb`: `resolve` by symbol and id, `alchemy_network`, explorer url.
5. README "Chains" list + CHANGELOG.

Applications can also define chains inline with `UncleBlockGiven::Chain.new(...)` without touching the gem; prefer
adding a constant only for networks Bolero actually targets.
