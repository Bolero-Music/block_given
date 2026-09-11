# frozen_string_literal: true

require "logger"

module UncleBlockGiven
  # Global configuration set through `UncleBlockGiven.configure { |c| ... }`.
  class Configuration
    attr_accessor :connector, :polling_interval, :timeout, :gas_multiplier, :base_fee_multiplier,
                  :confirmations, :abi_path, :max_block_range
    attr_reader :chain, :logger

    def initialize
      @connector = nil
      @chain = nil
      @polling_interval = 2.0     # seconds between two polls (receipts, blocks, events)
      @timeout = 180              # seconds before wait_for_transaction_receipt gives up
      @gas_multiplier = 1.2       # safety margin applied on top of eth_estimateGas
      @base_fee_multiplier = 1.2  # viem default: maxFeePerGas = baseFee * 1.2 + priorityFee
      @confirmations = 1
      @max_block_range = 2_000    # eth_getLogs ranges are split in chunks of this many blocks
      @abi_path = nil             # directory abi_file resolves relative paths against (e.g. Rails.root.join("abis"))
      @logger = Logger.new($stderr, level: Logger::WARN, progname: "uncle_block_given")
      @logger_configured = false
    end

    def logger=(logger)
      @logger = logger
      @logger_configured = true
    end

    # true once an application set its own logger (the Rails railtie respects it).
    def logger_configured? = @logger_configured

    # Accepts a UncleBlockGiven::Chain, a symbol (:base), a name ("base-sepolia") or a chain id (8453).
    def chain=(value)
      @chain = value.nil? ? nil : Chains.resolve(value)
    end

    def connector!
      connector || raise(ConfigurationError, "no connector configured: set UncleBlockGiven.config.connector " \
                                             "(e.g. UncleBlockGiven::Connectors::Alchemy.new(api_key: ...))")
    end

    def chain!
      chain || raise(ConfigurationError, "no chain configured: set UncleBlockGiven.config.chain (e.g. :base)")
    end
  end
end
