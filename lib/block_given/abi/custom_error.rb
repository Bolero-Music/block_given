# frozen_string_literal: true

module BlockGiven
  module Abi
    # Solidity custom error (`error InsufficientBalance(uint256 available, uint256 required)`).
    #
    # Used by `BlockGiven::ContractRevertError#decode_with` to name a revert and decode its arguments.
    #
    # @example
    #   error = interface.error_by_selector(revert_data[0, 10])
    #   error.signature           # => "InsufficientBalance(uint256,uint256)"
    #   error.decode(revert_data) # => { available: 5, required: 10 }
    class CustomError
      # @!attribute [r] name
      #   @return [String] the Solidity name (`"InsufficientBalance"`)
      # @!attribute [r] inputs
      #   @return [Array<Parameter>] the error arguments, in declaration order
      attr_reader :name, :inputs

      # Builds a custom error from its ABI definition.
      #
      # @param definition [Hash] the ABI entry (`"name"`, `"inputs"`), String or Symbol keys
      def initialize(definition)
        definition = definition.transform_keys(&:to_s)
        @name = definition["name"].to_s
        @inputs = Array(definition["inputs"]).each_with_index.map { |i, idx| Parameter.new(i, index: idx) }
      end

      # The canonical signature, with tuples expanded (`"InsufficientBalance(uint256,uint256)"`).
      #
      # @return [String]
      def signature = "#{name}(#{inputs.map(&:type).join(',')})"

      # The 4-byte selector: first 4 bytes of `keccak256(signature)`, `0x`-prefixed lowercase (memoized).
      #
      # @return [String]
      def selector = @selector ||= Utils.keccak256(signature)[0, 10]

      # Decodes the arguments of revert data produced by this error.
      #
      # The 4-byte selector at the start of the data is skipped, the remainder is decoded against
      # {#inputs} with {Coder.decode}.
      #
      # @param revert_data [String] the full revert data (`0x` + selector + encoded arguments)
      # @return [Hash{Symbol => Object}] decoded arguments keyed by snake_case name, in declaration order;
      #   empty for an error without arguments
      # @raise [BlockGiven::AbiError] when the data cannot be decoded against the inputs
      def decode(revert_data)
        payload = "0x#{Utils.strip_hex(revert_data)[8..]}"
        return {} if inputs.empty?

        inputs.map(&:ruby_name).zip(Coder.decode(inputs, payload)).to_h
      end

      # Compact representation with the signature.
      #
      # @return [String]
      def inspect = "#<BlockGiven::Abi::CustomError #{signature}>"
    end
  end
end
