---
name: test-matrix
description: Run or debug the full verification matrix (Ruby 3.1–3.4, Rails 7.0–8.0, coverage, gem build) before a PR or release, including the Docker-based runs and RAILS_COMPAT suite.
---

# Test matrix

Local Ruby is 3.1.2 (`.ruby-version`), matching the Bolero API. Other Rubies run in Docker.

```bash
bundle exec rake ci             # rspec + rubocop + gem build (fast, do this first)
COVERAGE=1 bundle exec rspec    # coverage/index.html, fails under 90% lines
bin/matrix                      # Ruby 3.2, 3.3, 3.4 (Docker, ~1 min each, needs Docker running)
bin/matrix rails 7.0            # Rails suites with local Ruby: 7.0, 7.1, 7.2 (8.0 needs Ruby >= 3.2)
bin/matrix rails 8.0 3.4        # Rails 8.0 under Docker Ruby 3.4
```

## How the Rails suite works

`RAILS_COMPAT=1` makes `spec_helper.rb` `require "rails/all"` before `vium`, so `Vium::Railtie` loads and
`spec/vium/railtie_spec.rb` runs (it boots a minimal `Rails::Application` and checks the logger wiring).
Gemfiles are in `gemfiles/rails_<version>.gemfile` and use `gemspec path: "../"`.

## Known pitfalls

- `rbsecp256k1` native build: use the system lib (`BUNDLE_BUILD__RBSECP256K1=--with-system-library`,
  `brew install secp256k1` / `apt-get install libsecp256k1-dev`). `bin/setup` does this automatically.
- Ruby 3.1 parser: anonymous block `&` with keyword args is a syntax error. Rubocop's `Naming/BlockForwarding`
  is disabled for that reason.
- Rails 7.1+ wraps `config.logger` in `ActiveSupport::BroadcastLogger`: compare with `Rails.logger`, not the
  logger you passed.
- Watcher specs poll with `sleep 0.01 until ... || deadline`; always `watcher.stop.join(1)` so no thread
  leaks into the next example (`Vium.reset!` in `before`/`after` also stops all watchers).
- Docker runs copy the repo read-only and delete lock files, so they never touch your local `Gemfile.lock`.
