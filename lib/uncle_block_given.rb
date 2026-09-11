# frozen_string_literal: true

require "eth"

require_relative "uncle_block_given/version"
require_relative "uncle_block_given/errors"
require_relative "uncle_block_given/utils"
require_relative "uncle_block_given/chain"
require_relative "uncle_block_given/configuration"
require_relative "uncle_block_given/connectors/base"
require_relative "uncle_block_given/connectors/http"
require_relative "uncle_block_given/connectors/alchemy"
require_relative "uncle_block_given/connectors/stub"
require_relative "uncle_block_given/normalizer"
require_relative "uncle_block_given/poller"
require_relative "uncle_block_given/receipt"
require_relative "uncle_block_given/transaction"
require_relative "uncle_block_given/client"
require_relative "uncle_block_given/wallet"
require_relative "uncle_block_given/abi/parameter"
require_relative "uncle_block_given/abi/coder"
require_relative "uncle_block_given/abi/function"
require_relative "uncle_block_given/abi/event"
require_relative "uncle_block_given/abi/custom_error"
require_relative "uncle_block_given/abi/interface"
require_relative "uncle_block_given/event"
require_relative "uncle_block_given/contract"
require_relative "uncle_block_given/railtie" if defined?(Rails::Railtie)

# viem-inspired toolkit to read from and write to EVM smart contracts.
#
#   UncleBlockGiven.configure do |c|
#     c.connector = UncleBlockGiven::Connectors::Alchemy.new(api_key: ENV["ALCHEMY_API_KEY"])
#     c.chain = :base
#   end
module UncleBlockGiven
  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
      @client = nil
      config
    end

    # Default client built from the global configuration.
    def client
      @client ||= Client.new
    end

    attr_writer :client

    # Running background watchers (see UncleBlockGiven::Watcher.find / stop / stop_all).
    def watchers = Watcher.all

    # Forget configuration and default client, stop every watcher (useful in tests).
    def reset!
      Watcher.stop_all(join: 1)
      @config = nil
      @client = nil
    end

    def logger = config.logger
  end
end
