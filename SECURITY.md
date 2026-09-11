# Security policy

## Supported versions

Only the latest minor release line receives security fixes.

## Reporting a vulnerability

Please do not open a public issue for security problems. Email remi@boleromusic.com with a description,
reproduction steps and the affected version. You will get an acknowledgement within a few business days and
a fix or mitigation plan as soon as the issue is confirmed.

## What counts

Anything that could expose a private key or an RPC API key (in logs, exceptions, `inspect` output, error
payloads), sign or broadcast something the caller did not ask for, mis-encode ABI data in a way that changes
the on-chain effect of a call, or make the client trust unverified RPC responses for safety-relevant
decisions (receipt status, revert reasons).

## Handling keys in your own code

- Load private keys and API keys from the environment, Rails credentials or a secret manager. Never commit
  them; `.env` is git-ignored and `.env.example` documents the expected variables.
- `BlockGiven::Wallet#inspect` hides the key and connectors mask API keys, but the raw signed transaction returned
  by `sign_transaction` is public data by design: it can be rebroadcast by anyone who sees it.
