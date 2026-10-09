# frozen_string_literal: true

module BlockGiven
  module Abi
    # One ABI function: encodes calldata from Ruby arguments and decodes return data.
    #
    # @example
    #   transfer = interface.function(:transfer)
    #   transfer.signature                         # => "transfer(address,uint256)"
    #   transfer.selector                          # => "0xa9059cbb"
    #   transfer.encode([to, 1_000_000])           # => "0xa9059cbb000000..."
    #   transfer.encode([], { to: to, value: 1e6 }) # keyword form, same result
    #   transfer.decode_output("0x0000...0001")    # => true
    class Function
      # @!attribute [r] name
      #   @return [String] the Solidity name (`"balanceOf"`)
      # @!attribute [r] inputs
      #   @return [Array<Parameter>] the input parameters, in declaration order
      # @!attribute [r] outputs
      #   @return [Array<Parameter>] the output parameters, in declaration order
      # @!attribute [r] state_mutability
      #   @return [String] `"view"`, `"pure"`, `"nonpayable"` or `"payable"`
      attr_reader :name, :inputs, :outputs, :state_mutability

      # Builds a function from its ABI definition.
      #
      # Pre-Solidity 0.5 ABIs without `stateMutability` are supported: `payable: true` maps to
      # `"payable"`, `constant: true` to `"view"`, anything else to `"nonpayable"`.
      #
      # @param definition [Hash] the ABI entry (`"name"`, `"inputs"`, `"outputs"`, `"stateMutability"`),
      #   String or Symbol keys
      def initialize(definition)
        definition = definition.transform_keys(&:to_s)
        @name = definition["name"].to_s
        @inputs = Array(definition["inputs"]).each_with_index.map { |i, idx| Parameter.new(i, index: idx) }
        @outputs = Array(definition["outputs"]).each_with_index.map { |o, idx| Parameter.new(o, index: idx) }
        @state_mutability = (definition["stateMutability"] || legacy_mutability(definition)).to_s
      end

      # The snake_case Ruby method name (`balanceOf` becomes `:balance_of`).
      #
      # @return [Symbol]
      def ruby_name = Utils.snake_case(name).to_sym

      # The canonical signature, with tuples expanded (`"transfer(address,uint256)"`).
      #
      # @return [String]
      def signature = "#{name}(#{inputs.map(&:type).join(',')})"

      # The 4-byte selector: first 4 bytes of `keccak256(signature)`, `0x`-prefixed lowercase (memoized).
      #
      # @return [String]
      def selector = @selector ||= Utils.keccak256(signature)[0, 10]

      # Whether the function is `view` or `pure`, i.e. served by `eth_call`.
      #
      # @return [Boolean]
      def read? = %w[view pure].include?(state_mutability)

      # Whether the function needs a transaction (`nonpayable` or `payable`).
      #
      # @return [Boolean]
      def write? = !read?

      # Whether the function accepts ether (`payable`).
      #
      # @return [Boolean]
      def payable? = state_mutability == "payable"

      # The snake_case names of the inputs, in declaration order (unnamed inputs get `:argN`).
      #
      # @return [Array<Symbol>]
      def input_names = inputs.map(&:ruby_name)

      # ABI-encodes a call: selector followed by the encoded arguments.
      #
      # Arguments are given positionally or by keyword (matched on snake_cased input names, see
      # {#resolve_args}) and coerced with {Coder.encode}.
      #
      # @param args [Array] positional arguments, in declaration order
      # @param kwargs [Hash] keyword arguments by input name (any case); exclusive with `args`
      # @return [String] `0x`-prefixed calldata
      # @raise [BlockGiven::InvalidArgumentError] when positional and keyword arguments are mixed, when
      #   keywords are used with unnamed inputs, on unknown or missing keywords, on a wrong argument count
      #   or when a value cannot be coerced to its Solidity type
      # @raise [BlockGiven::InvalidAddressError] when an address argument is malformed
      # @raise [BlockGiven::AbiError] when the underlying ABI encoder rejects a value
      # @example
      #   transfer.encode([to, 1_000_000])
      #   transfer.encode([], { to: to, value: 1_000_000 })
      def encode(args = [], kwargs = {})
        values = resolve_args(args, kwargs)
        selector + Utils.strip_hex(Coder.encode(inputs, values))
      end

      # Decodes return data into Ruby values (see {Coder.decode} for the formatting rules).
      #
      # @param hex [String] the `0x`-prefixed return data of `eth_call`
      # @return [Object] the single output value when the function has one output
      # @return [Array<Object>] one value per output otherwise (empty Array for no outputs)
      # @raise [BlockGiven::AbiError] when the data is empty (no contract at the address, typically) or
      #   cannot be decoded
      # @example
      #   balance_of.decode_output("0x00000000000000000000000000000000000000000000000000000000000f4240")
      #   # => 1000000
      def decode_output(hex)
        values = Coder.decode(outputs, hex)
        outputs.size == 1 ? values.first : values
      end

      # Turns positional or keyword arguments into the positional Array expected by the encoder.
      #
      # Keyword names are matched after `Utils.snake_case` (leading underscores stripped, camelCase
      # converted), so `_to`, `to` and `To` all designate the same input.
      #
      # @api private
      # @param args [Array] positional arguments
      # @param kwargs [Hash] keyword arguments
      # @return [Array] values in input declaration order
      # @raise [BlockGiven::InvalidArgumentError] when both forms are mixed, when the ABI inputs are
      #   unnamed, or on unknown / missing keywords
      def resolve_args(args, kwargs)
        raise InvalidArgumentError, "#{name}: mix of positional and keyword arguments" if !args.empty? && !kwargs.empty?
        return args if kwargs.empty?

        if inputs.any?(&:unnamed?)
          raise InvalidArgumentError, "#{name}: inputs are unnamed in the ABI, use positional arguments"
        end

        normalized = kwargs.transform_keys { |k| Utils.snake_case(k).to_sym }
        unknown = normalized.keys - input_names
        unless unknown.empty?
          raise InvalidArgumentError,
                "#{name}: unknown argument(s) #{unknown.join(', ')} (expected #{input_names.join(', ')})"
        end

        missing = input_names - normalized.keys
        raise InvalidArgumentError, "#{name}: missing argument(s) #{missing.join(', ')}" unless missing.empty?

        input_names.map { |n| normalized[n] }
      end

      # The canonical signature (same as {#signature}).
      #
      # @return [String]
      def to_s = signature

      # Compact representation with the signature and state mutability.
      #
      # @return [String]
      def inspect = "#<BlockGiven::Abi::Function #{signature} #{state_mutability}>"

      private

      # State mutability for pre-0.5 ABIs that only carry `payable` / `constant` flags.
      def legacy_mutability(definition)
        return "payable" if definition["payable"]
        return "view" if definition["constant"]

        "nonpayable"
      end
    end
  end
end
