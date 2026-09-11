# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

desc "Run RuboCop"
task(:lint) { sh "bundle exec rubocop" }

desc "Specs with coverage report (COVERAGE=1)"
task(:coverage) { sh "COVERAGE=1 bundle exec rspec" }

desc "Generate the API documentation into doc/ (YARD)"
task(:doc) { sh "bundle exec yard doc" }

desc "Fail when a public method, class, module or constant lacks YARD documentation"
task :doc_check do
  output = `bundle exec yard stats --list-undoc --fail-on-warning 2>&1`
  puts output
  complete = Process.last_status.success? && output.include?("100.00% documented")
  abort "doc_check: YARD warnings or undocumented objects above" unless complete
end

desc "Everything CI runs: specs, lint, doc coverage, gem build"
task ci: %i[spec lint doc_check] do
  sh "gem build block_given.gemspec"
  sh "rm -f block_given-*.gem"
end

task default: :ci
