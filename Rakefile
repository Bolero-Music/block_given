# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

desc "Run RuboCop"
task(:lint) { sh "bundle exec rubocop" }

desc "Specs with coverage report (COVERAGE=1)"
task(:coverage) { sh "COVERAGE=1 bundle exec rspec" }

desc "Everything CI runs: specs, lint, gem build"
task ci: %i[spec lint] do
  sh "gem build uncle_block_given.gemspec"
  sh "rm -f uncle_block_given-*.gem"
end

task default: :ci
