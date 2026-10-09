# frozen_string_literal: true

require "logger"

module BlockGiven
  # Global configuration set through {BlockGiven.configure}.
  #
  # Every option has a default, so an application only has to provide a {#connector} and a {#chain}. Values
  # are read lazily by {Client} (polling interval, timeout, confirmations, fee multipliers, block range),
  # {Wallet} ({#gas_multiplier}), {Contract.abi_file} ({#abi_path}) and the Rails railtie ({#logger}), so
  # changing them affects clients that were already built.
  #
  # @example
  #   BlockGiven.configure do |c|
  #     c.connector = BlockGiven::Connectors::Alchemy.new(api_key: ENV["ALCHEMY_API_KEY"])
  #     c.chain = :base
  #     c.abi_path = Rails.root.join("abis")
  #     c.confirmations = 2
  #   end
  #
  # @!attribute [rw] connector
  #   JSON-RPC transport used by the default client and by contracts without an explicit connector
  #   (default `nil`, required). Any {Connectors::Base} implementation: {Connectors::Alchemy},
  #   {Connectors::Http}, or {Connectors::Stub} in tests.
  #   @return [BlockGiven::Connectors::Base, nil]
  # @!attribute [rw] polling_interval
  #   Seconds between two polls when waiting for a receipt, watching blocks or watching events
  #   (default `2.0`).
  #   @return [Float, Integer]
  # @!attribute [rw] timeout
  #   Seconds before {Client#wait_for_transaction_receipt} gives up with a {TimeoutError} (default `180`).
  #   `nil` waits forever.
  #   @return [Float, Integer, nil]
  # @!attribute [rw] gas_multiplier
  #   Safety margin applied on top of `eth_estimateGas` when a wallet fills in the gas limit of a
  #   transaction: `gas = ceil(estimate * gas_multiplier)` (default `1.2`).
  #   @return [Float]
  # @!attribute [rw] base_fee_multiplier
  #   Multiplier applied to the latest block base fee when {Client#estimate_fees_per_gas} computes
  #   `maxFeePerGas = baseFee * base_fee_multiplier + maxPriorityFeePerGas` (default `1.2`, viem's default).
  #   @return [Float]
  # @!attribute [rw] confirmations
  #   Number of blocks, including the mining block, a receipt must have before
  #   {Client#wait_for_transaction_receipt} and {Transaction#confirmed?} consider it final (default `1`, i.e. as
  #   soon as the transaction is mined).
  #   @return [Integer]
  # @!attribute [rw] abi_path
  #   Directory {Contract.abi_file} resolves relative paths against, e.g. `Rails.root.join("abis")`
  #   (default `nil`: relative paths are resolved from the current working directory). ABIs belong to the
  #   application, the gem ships none.
  #   @return [String, Pathname, nil]
  # @!attribute [rw] max_block_range
  #   Maximum number of blocks per `eth_getLogs` request; {Client#get_logs_in_chunks} and
  #   {Client#watch_logs} split wider ranges into chunks of this size to respect provider caps
  #   (default `2_000`).
  #   @return [Integer]
  # @!attribute [r] chain
  #   Network the default client talks to (default `nil`, required). Assigned through {#chain=}, which accepts
  #   anything {Chains.resolve} understands.
  #   @return [BlockGiven::Chain, nil]
  # @!attribute [r] logger
  #   Logger used by clients, connectors and watchers (default: a `Logger` writing to `$stderr` at `WARN`
  #   level with progname `"block_given"`). Assigning one through {#logger=} marks it as application-provided,
  #   which stops the Rails railtie from installing `Rails.logger`.
  #   @return [Logger]
  class Configuration
    attr_accessor :connector, :polling_interval, :timeout, :gas_multiplier, :base_fee_multiplier,
                  :confirmations, :abi_path, :max_block_range
    attr_reader :chain, :logger

    # Build a configuration holding the defaults documented on each attribute.
    #
    # @return [Configuration]
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
      @logger = Logger.new($stderr, level: Logger::WARN, progname: "block_given")
      @logger_configured = false
    end

    # Set the logger and remember that the application provided it (see {#logger_configured?}).
    #
    # @param logger [Logger] any object responding to `debug`, `info`, `warn` and `error`
    # @return [Logger] the assigned logger
    def logger=(logger)
      @logger = logger
      @logger_configured = true
    end

    # Whether an application set its own logger through {#logger=}.
    #
    # The Rails railtie only installs `Rails.logger` when this is false, so an explicit logger always wins.
    #
    # @return [Boolean]
    def logger_configured? = @logger_configured

    # Set the chain from a {Chain}, a symbol (`:base`), a network name (`"base-sepolia"`) or a chain id (`8453`).
    #
    # @param value [BlockGiven::Chain, Symbol, String, Integer, nil] nil clears the chain
    # @return [BlockGiven::Chain, nil] the resolved chain
    # @raise [BlockGiven::ConfigurationError] when the value does not match a known chain (see {Chains.resolve})
    def chain=(value)
      @chain = value.nil? ? nil : Chains.resolve(value)
    end

    # Return the connector or raise when none was configured.
    #
    # @return [BlockGiven::Connectors::Base]
    # @raise [BlockGiven::ConfigurationError] when {#connector} is nil
    def connector!
      connector || raise(ConfigurationError, "no connector configured: set BlockGiven.config.connector " \
                                             "(e.g. BlockGiven::Connectors::Alchemy.new(api_key: ...))")
    end

    # Return the chain or raise when none was configured.
    #
    # @return [BlockGiven::Chain]
    # @raise [BlockGiven::ConfigurationError] when {#chain} is nil
    def chain!
      chain || raise(ConfigurationError, "no chain configured: set BlockGiven.config.chain (e.g. :base)")
    end
  end
end
