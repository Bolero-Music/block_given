# frozen_string_literal: true

require_relative "lib/block_given/version"

Gem::Specification.new do |spec|
  spec.name = "block_given"
  spec.version = BlockGiven::VERSION
  spec.authors = ["Remi Wallaere"]
  spec.email = ["remi@boleromusic.com"]

  spec.summary = "viem-inspired Ruby client for EVM smart contracts."
  spec.description = <<~DESC
    BlockGiven lets you talk to EVM smart contracts from Ruby with a small, explicit API
    inspired by viem: typed contract classes generated from an ABI, wallets that sign
    EIP-1559 transactions, pluggable JSON-RPC connectors (Alchemy first) and
    polling helpers for receipts, blocks and events.
  DESC
  spec.homepage = "https://github.com/Bolero-Music/block_given"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["documentation_uri"] = "https://rubydoc.info/gems/block_given"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]

  spec.add_dependency "bigdecimal", ">= 3.1"
  spec.add_dependency "eth", "~> 0.5", ">= 0.5.17"
  spec.add_dependency "logger", ">= 1.5"
end
