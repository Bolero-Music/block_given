---
name: release
description: Cut a uncle_block_given release — version bump, CHANGELOG, verification matrix, tag, RubyGems publication via trusted publishing or rake release.
---

# Release

1. **Decide the version** (semver). Breaking public API → major; new API → minor; fixes → patch.
2. **Update** `lib/uncle_block_given/version.rb`.
3. **CHANGELOG**: move `Unreleased` entries under `## [X.Y.Z] - YYYY-MM-DD`, add the compare links at the
   bottom, leave an empty `## [Unreleased]`.
4. **Verify**: `bundle exec rake ci`, `COVERAGE=1 bundle exec rspec`, `bin/matrix`, `bin/matrix rails 7.0`
   and `bin/matrix rails 8.0 3.4`. Build and install the gem in a clean GEM_HOME:
   ```bash
   gem build uncle_block_given.gemspec && GEM_HOME=$(mktemp -d) gem install --local --ignore-dependencies ./uncle_block_given-X.Y.Z.gem
   tar -xOf uncle_block_given-X.Y.Z.gem data.tar.gz | tar -tz     # only lib/, README, CHANGELOG, LICENSE
   ```
5. **Commit** `Release vX.Y.Z`, push `main`, then tag: `git tag vX.Y.Z && git push origin vX.Y.Z`.
   Tagging and pushing are outward-facing: confirm with the maintainer before doing them.
6. **Publish**: the `Release` workflow (`.github/workflows/release.yml`) checks the tag matches
   `UncleBlockGiven::VERSION`, runs the suite and publishes with RubyGems trusted publishing. Fallback from a maintainer
   machine: `bundle exec rake release` (needs `~/.gem/credentials` with MFA).
7. **After**: create the GitHub release from the tag with the CHANGELOG section as notes; bump the API's
   Gemfile.

## One-time setup (already documented in release.yml)

RubyGems → gem `uncle_block_given` → Trusted publishers → GitHub Actions: repository `Bolero-Music/uncle_block_given`, workflow
`release.yml`, environment `release`. Create the `release` environment in the GitHub repo settings
(optionally with required reviewers).
