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
#   BlockGiven.configure do |c|
#     c.connector = BlockGiven::Connectors::Alchemy.new(api_key: ENV["ALCHEMY_API_KEY"])
#     c.chain = :base
#   end
module BlockGiven
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

    # Running background watchers (see BlockGiven::Watcher.find / stop / stop_all).
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
