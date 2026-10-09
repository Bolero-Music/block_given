# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "rake", "~> 13.0"
  gem "rspec", "~> 3.12"
  gem "rubocop", "~> 1.50", require: false
  gem "simplecov", "~> 0.22", require: false
  gem "webmock", "~> 3.18"
  gem "yard", "~> 0.9", require: false
end

# Rails compatibility suites live in gemfiles/rails_*.gemfile:
#   BUNDLE_GEMFILE=gemfiles/rails_7.2.gemfile RAILS_COMPAT=1 bundle exec rspec
