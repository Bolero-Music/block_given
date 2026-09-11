---
name: add-connector
description: Implement a new JSON-RPC connector/transport (Infura, QuickNode, WebSocket, local node) or change HTTP retry/redaction behaviour. Use when touching lib/uncle_block_given/connectors.
---

# Add a connector

A connector is a transport: `request(method, params, chain:)` returns the JSON-RPC `result` or raises
`UncleBlockGiven::RpcError`. Everything above it (Client, Contract) stays unchanged.

## Steps

1. **Pick the base class.** HTTP providers subclass `Connectors::Http` and override `endpoint(chain)` (and
   `redact` if the URL carries a key). Non-HTTP transports subclass `Connectors::Base` and implement
   `request` + optionally `batch`.
2. **Endpoint from the chain.** Multi-network providers derive the URL from `chain` (see `Alchemy#endpoint`
   and the `alchemy_network` field on `Chain`). Add a provider-specific slug to `Chain` only if needed;
   raise `ConfigurationError` for unsupported chains.
3. **Redaction is mandatory.** Implement `redact(endpoint)` so the key never appears in `inspect`, logs or
   `HttpError` messages. `Http#redact` keeps scheme/host/port and masks the path by default; keep the network
   host visible when the provider encodes it there (Alchemy pattern).
4. **Errors**: HTTP failures → `HttpError` (status, body); JSON-RPC errors → `RpcError.from_payload` (which
   detects reverts). Retry only on `RETRIABLE_STATUSES` / `RETRIABLE_RPC_CODES` / connection exceptions, with
   the existing backoff. Never retry a revert.
5. **Specs** in `spec/uncle_block_given/connectors/<name>_spec.rb` using WebMock (`stub_request`): endpoint per chain,
   happy path, RPC error payload, retry on 429 then success, error message contains the host but not the key,
   `inspect` without the key.
6. **Docs**: README "Connectors" table row + CHANGELOG.

## Checklist

- [ ] `endpoint(chain)` raises `ConfigurationError` for unknown/unsupported chains
- [ ] `redact` covered by a spec asserting the secret is absent
- [ ] constructor validates required credentials (empty key → `ConfigurationError`)
- [ ] thread-safe: no shared mutable state without a Mutex (`Http#next_id` shows the pattern)
