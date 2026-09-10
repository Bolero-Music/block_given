# frozen_string_literal: true

require "eth"

require_relative "vium/version"
require_relative "vium/errors"
require_relative "vium/utils"
require_relative "vium/chain"
require_relative "vium/configuration"
require_relative "vium/connectors/base"
require_relative "vium/connectors/http"
require_relative "vium/connectors/alchemy"
require_relative "vium/connectors/stub"
require_relative "vium/normalizer"
require_relative "vium/poller"
require_relative "vium/receipt"
require_relative "vium/transaction"
require_relative "vium/client"
require_relative "vium/wallet"
require_relative "vium/abi/parameter"
require_relative "vium/abi/coder"
require_relative "vium/abi/function"
require_relative "vium/abi/event"
require_relative "vium/abi/custom_error"
require_relative "vium/abi/interface"
require_relative "vium/event"
require_relative "vium/contract"
require_relative "vium/railtie" if defined?(Rails::Railtie)

# viem-inspired toolkit to read from and write to EVM smart contracts.
#
#   Vium.configure do |c|
#     c.connector = Vium::Connectors::Alchemy.new(api_key: ENV["ALCHEMY_API_KEY"])
#     c.chain = :base
#   end
module Vium
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

    # Running background watchers (see Vium::Watcher.find / stop / stop_all).
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
