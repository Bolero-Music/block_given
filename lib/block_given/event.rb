# frozen_string_literal: true

module BlockGiven
  # A log decoded against an ABI event definition (see `Abi::Event#decode`).
  #
  # {#args} holds the decoded parameters keyed by their snake_case name, in ABI declaration order (indexed and
  # non-indexed inputs interleaved as declared). Indexed parameters of dynamic type (`string`, `bytes`,
  # arrays, tuples) cannot be recovered from a log: their value is the keccak-256 topic hash as `0x` hex.
  # {#log} keeps the raw normalized log the event was decoded from.
  #
  # @example
  #   event.name           # => "Transfer"
  #   event.args           # => { from: "0x...", to: "0x...", value: 1000000 }
  #   event[:value]        # => 1000000
  #   event["value"]       # => 1000000 (String keys are snake_cased and symbolized)
  #   event.block_number   # => 12345
  class Event
    # @!attribute [r] name
    #   @return [String] the event name as declared in the ABI, e.g. `"Transfer"`
    # @!attribute [r] signature
    #   @return [String] the canonical signature, e.g. `"Transfer(address,address,uint256)"`
    # @!attribute [r] args
    #   @return [Hash{Symbol => Object}] decoded parameters keyed by snake_case name, in ABI declaration order;
    #     addresses checksummed, integers as Integer, static bytes as `0x` hex, indexed dynamic types as their
    #     topic hash
    # @!attribute [r] log
    #   @return [Hash{Symbol => Object}] the raw normalized log (`:address`, `:topics`, `:data`, `:block_number`,
    #     `:transaction_hash`, `:log_index`, `:removed`...)
    attr_reader :name, :signature, :args, :log

    # Builds a decoded event. Instances are normally created by `Abi::Event#decode` rather than directly.
    #
    # @param name [String] the event name
    # @param signature [String] the canonical event signature
    # @param args [Hash{Symbol => Object}] the decoded parameters, keyed by snake_case Symbol
    # @param log [Hash{Symbol => Object}] the normalized log the event was decoded from
    def initialize(name:, signature:, args:, log:)
      @name = name
      @signature = signature
      @args = args
      @log = log
    end

    # Reads a decoded parameter by name.
    #
    # @param key [Symbol, String] the parameter name, in camelCase or snake_case (`:tokenId`, `"token_id"`...)
    # @return [Object, nil] the decoded value, or nil when the event has no such parameter
    def [](key) = args[Utils.snake_case(key).to_sym]

    # @return [String, nil] the EIP-55 checksummed address of the contract that emitted the log, or nil when
    #   the log carries no address
    def address = log[:address] && Utils.checksum_address(log[:address])

    # @return [Integer, nil] the number of the block containing the log (nil for a pending log)
    def block_number = log[:block_number]

    # @return [String, nil] the hash of the containing block as `0x` hex
    def block_hash = log[:block_hash]

    # @return [String, nil] the hash of the emitting transaction as `0x` hex
    def transaction_hash = log[:transaction_hash]

    # @return [Integer, nil] the position of the emitting transaction in its block
    def transaction_index = log[:transaction_index]

    # @return [Integer, nil] the position of the log in its block
    def log_index = log[:log_index]

    # @return [Boolean] true when the node flagged the log as removed by a chain reorganisation
    def removed? = !!log[:removed]

    # A compact Hash view, handy for persistence or logging.
    #
    # @return [Hash{Symbol => Object}] `:name`, `:args`, `:address` (checksummed), `:block_number`,
    #   `:transaction_hash` and `:log_index`
    def to_h
      { name: name, args: args, address: address, block_number: block_number,
        transaction_hash: transaction_hash, log_index: log_index }
    end

    # Debug representation with the name, decoded args and block number.
    #
    # @return [String] e.g. `#<BlockGiven::Event Transfer {:from=>"0x...", ...} block=123>`
    def inspect = "#<BlockGiven::Event #{name} #{args.inspect} block=#{block_number}>"
  end
end
