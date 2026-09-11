# frozen_string_literal: true

require "eth"

require_relative "block_given/version"
require_relative "block_given/errors"
require_relative "block_given/utils"
require_relative "block_given/chain"
require_relative "block_given/configuration"
require_relative "block_given/connectors/base"
require_relative "block_given/connectors/http"
require_relative "block_given/connectors/alchemy"
require_relative "block_given/connectors/stub"
require_relative "block_given/normalizer"
require_relative "block_given/poller"
require_relative "block_given/receipt"
require_relative "block_given/transaction"
require_relative "block_given/signed_transaction"
require_relative "block_given/client"
require_relative "block_given/wallet"
require_relative "block_given/abi/parameter"
require_relative "block_given/abi/coder"
require_relative "block_given/abi/function"
require_relative "block_given/abi/event"
require_relative "block_given/abi/custom_error"
require_relative "block_given/abi/interface"
require_relative "block_given/event"
require_relative "block_given/contract"
require_relative "block_given/railtie" if defined?(Rails::Railtie)

# viem-inspired toolkit to read from and write to EVM smart contracts.
#
# The gem is organised around a handful of entry points:
#
# - {BlockGiven.configure} sets the global {Configuration}: JSON-RPC connector, chain, polling and fee
#   defaults, and the directory application ABIs live in.
# - {BlockGiven.client} returns the default {Client}: thin wrappers over JSON-RPC (`eth_*`) that return Ruby
#   values (Integer quantities in wei, checksummed addresses, snake_case symbol keys), plus fee estimation,
#   receipt polling, log fetching and stoppable `watch_*` pollers.
# - {Contract} is a class-level DSL (`abi_file`, `address`, `chain`) that generates typed read, write and
#   simulate methods and decoded events from an ABI.
# - {Wallet} holds a private key and signs transactions (EIP-1559 and legacy), personal messages (EIP-191)
#   and typed data (EIP-712).
# - {Connectors} carry the transport: {Connectors::Alchemy} and {Connectors::Http} for real nodes,
#   {Connectors::Stub} for tests.
# - {Utils}, {Normalizer} and {Chains} are stateless helpers (unit parsing, hex handling, keccak256,
#   RPC payload normalisation and the catalogue of known networks).
#
# Every error raised by the gem inherits from {BlockGiven::Error}.
#
# @example Configure once, then use the default client
#   BlockGiven.configure do |c|
#     c.connector = BlockGiven::Connectors::Alchemy.new(api_key: ENV["ALCHEMY_API_KEY"])
#     c.chain = :base
#   end
#
#   BlockGiven.client.block_number # => 12_345_678
module BlockGiven
  class << self
    # Global configuration shared by the default client and by contracts without an explicit chain or connector.
    #
    # @return [BlockGiven::Configuration] the memoised configuration, created with defaults on first access
    def config
      @config ||= Configuration.new
    end

    # Configure the gem and discard the memoised default client so the next {.client} call reflects the changes.
    #
    # @yield [config] the global configuration to mutate
    # @yieldparam config [BlockGiven::Configuration]
    # @return [BlockGiven::Configuration] the updated configuration
    # @example
    #   BlockGiven.configure do |c|
    #     c.connector = BlockGiven::Connectors::Alchemy.new(api_key: ENV["ALCHEMY_API_KEY"])
    #     c.chain = :base_sepolia
    #     c.polling_interval = 1.0
    #     c.abi_path = Rails.root.join("abis")
    #   end
    def configure
      yield config
      @client = nil
      config
    end

    # Default client built from the global configuration.
    #
    # Memoised until {.configure} or {.reset!} runs, or until a client is assigned through {.client=}.
    #
    # @return [BlockGiven::Client]
    # @raise [BlockGiven::ConfigurationError] when no connector or no chain is configured
    # @example
    #   BlockGiven.client.get_balance("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045") # => 1_000_000_000_000_000_000
    def client
      @client ||= Client.new
    end

    # Replace the default client, for instance with one built on a {Connectors::Stub} in tests.
    #
    # @param value [BlockGiven::Client, nil] nil makes the next {.client} call rebuild one from the configuration
    # @return [BlockGiven::Client, nil]
    attr_writer :client

    # Running background watchers, oldest first (see {Watcher.find}, {Watcher.stop} and {Watcher.stop_all}).
    #
    # @return [Array<BlockGiven::Watcher>]
    def watchers = Watcher.all

    # Forget configuration and default client, and stop every watcher (useful in tests).
    #
    # Watchers are asked to stop gracefully and joined for up to one second each before the state is cleared.
    #
    # @return [void]
    def reset!
      Watcher.stop_all(join: 1)
      @config = nil
      @client = nil
    end

    # Logger from the global configuration.
    #
    # @return [Logger] a `$stderr` logger at WARN level unless the application set one (see {Configuration#logger})
    def logger = config.logger
  end
end
