# Contributing to BlockGiven

Thanks for helping. This document covers setup, how we test, and the conventions reviewers will look for.

## Setup

```bash
git clone git@github.com:Bolero-Music/block_given.git && cd block_given
bin/setup            # bundle install, with the libsecp256k1 hint if the native build fails
bundle exec rspec
bundle exec rubocop
```

The `eth` dependency compiles `rbsecp256k1`. If the bundled libsecp256k1 download fails:
`brew install secp256k1` (macOS) or `apt-get install libsecp256k1-dev` (Debian/Ubuntu), then
`bundle config build.rbsecp256k1 --with-system-library` and `bundle install` again.

## Running the full matrix

```bash
bin/matrix                    # Ruby 3.2, 3.3, 3.4 in Docker (3.1 is your local Ruby)
bin/matrix 3.4                # one Ruby
bin/matrix rails 7.2          # Rails compat suite (local Ruby)
bin/matrix rails 8.0 3.4      # Rails 8.0 under Ruby 3.4 in Docker
COVERAGE=1 bundle exec rspec  # coverage report, 90% line minimum enforced
```

CI runs the same matrix on every push and pull request.

## Conventions

- **No network in specs.** Use `BlockGiven::Connectors::Stub` for RPC responses and WebMock for the HTTP layer.
  A read-only check against a public RPC is fine locally, never in the suite.
- **Secrets never reach logs.** Anything that can end up in `inspect`, an exception message or a log line
  goes through `Http#redact` or an equivalent. Add a spec proving the key is absent.
- **`tx:` is the only reserved keyword** on contract methods; every other keyword maps to an ABI input.
  Transaction/call overrides go there, never as top-level keywords.
- **No application ABI ships in the gem.** Only frozen standards do (`lib/block_given/abis/`, EIP-20/721/1155/4626);
  applications own the ABIs of their own contracts. Spec fixtures live in `spec/fixtures/`.
- **Ruby 3.1 is the floor.** Avoid syntax newer than 3.1 (no `it` block param, no `Data.define`), and beware
  that an anonymous block `&` combined with keyword arguments is a syntax error on 3.1.
- **Every user-visible change gets a CHANGELOG line** under `Unreleased`, and README docs when it adds API.
- **RuboCop clean, coverage ≥ 90%.** `bundle exec rubocop -a` handles most style issues.
- **Semantic versioning.** Breaking changes to `Contract`, `Wallet`, `Client`, connectors or `Utils` bump the
  major version.

## Working with Claude Code

`CLAUDE.md` describes the layout and the rules above for AI-assisted sessions. `.claude/skills/` holds
playbooks for recurring tasks (adding a client method, a connector, a chain, running the matrix, releasing,
debugging RPC issues) and `.claude/agents/gem-reviewer.md` a pre-PR reviewer. `.claude/settings.json`
pre-approves the test and lint commands and asks before anything outward-facing (push, tag, gem push).

## Pull requests

1. Branch from `main`, keep the PR focused.
2. Add specs for the change (unit, plus a Rails compat consideration if it touches loading or logging).
3. Update `CHANGELOG.md` and, if relevant, `README.md`.
4. Make sure `bundle exec rspec`, `bundle exec rubocop` and `gem build block_given.gemspec` pass.
5. Describe the motivation in the PR; link the issue if there is one.

Commit messages: imperative summary line under 72 characters, blank line, then the why.

## Releasing (maintainers)

See the "Versioning & releases" section of the README. In short: bump `lib/block_given/version.rb`, move the
`Unreleased` notes under the new version with today's date, commit, then `bundle exec rake release`
(or push a `vX.Y.Z` tag to let the release workflow publish through RubyGems trusted publishing).
