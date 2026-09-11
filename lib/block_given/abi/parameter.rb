# frozen_string_literal: true

module BlockGiven
  module Abi
    # One ABI input/output. Knows its canonical Solidity type (`"(uint256,address)[]"`).
    #
    # Parameters describe function inputs and outputs, event parameters, custom error arguments and
    # tuple components. Unnamed parameters get a positional name (`arg0`, `arg1`...) so they can still
    # be addressed, and are flagged with {#unnamed?}.
    class Parameter
      # @!attribute [r] name
      #   @return [String] the ABI name, or `"argN"` (N = position) when the ABI leaves it empty
      # @!attribute [r] raw_type
      #   @return [String] the type as written in the ABI (`"uint256"`, `"tuple[]"`, `"address[2]"`)
      # @!attribute [r] components
      #   @return [Array<Parameter>] the tuple components (empty for non-tuple types)
      # @!attribute [r] indexed
      #   @return [Boolean] whether an event parameter is `indexed`
      # @!attribute [r] internal_type
      #   @return [String, nil] the Solidity-side type from the ABI (`"struct Order"`, `"contract IERC20"`)
      #     when present
      attr_reader :name, :raw_type, :components, :indexed, :internal_type

      # Builds a parameter from its ABI definition.
      #
      # @param definition [Hash] the ABI entry (`"name"`, `"type"`, `"components"`, `"indexed"`,
      #   `"internalType"`), String or Symbol keys
      # @param index [Integer] position of the parameter, used to name unnamed ones (`"arg#{index}"`)
      def initialize(definition, index: 0)
        definition = definition.transform_keys(&:to_s)
        @name = definition["name"].to_s
        @name = "arg#{index}" if @name.empty?
        @unnamed = definition["name"].to_s.empty?
        @raw_type = definition["type"].to_s
        @indexed = definition["indexed"] ? true : false
        @internal_type = definition["internalType"]
        @components = Array(definition["components"]).each_with_index.map { |c, i| Parameter.new(c, index: i) }
      end

      # Whether the ABI gives no name to this parameter (keyword arguments are then unavailable).
      #
      # @return [Boolean]
      def unnamed? = @unnamed

      # Whether this event parameter is `indexed`.
      #
      # @return [Boolean]
      def indexed? = indexed

      # The snake_case Symbol used for keyword arguments and decoded Hash keys (`_to` becomes `:to`,
      # `tokenId` becomes `:token_id`).
      #
      # @return [Symbol]
      def ruby_name = Utils.snake_case(name).to_sym

      # Whether the type is a tuple or an array of tuples (`"tuple"`, `"tuple[]"`, `"tuple[2]"`).
      #
      # @return [Boolean]
      def tuple? = raw_type.start_with?("tuple")

      # Whether the type is an array, fixed (`"uint256[2]"`) or dynamic (`"uint256[]"`).
      #
      # @return [Boolean]
      def array? = raw_type.end_with?("]")

      # The canonical type used in signatures, with tuples expanded from their components.
      #
      # @return [String] for example `"(uint256,address)[]"` for `"tuple[]"` with two components
      def type
        return raw_type unless tuple?

        raw_type.sub("tuple", "(#{components.map(&:type).join(',')})")
      end

      # The element parameter of an array type, i.e. this type without its outermost array dimension.
      #
      # @return [Parameter] a parameter with the same name and components, for `"uint256[][2]"` the
      #   element is `"uint256[]"`
      # @return [nil] when the type is not an array
      def element
        return nil unless array?

        Parameter.new(
          { "name" => name, "type" => raw_type.sub(/\[\d*\]\z/, ""),
            "components" => components.map(&:to_h) }
        )
      end

      # Whether the type is dynamically sized in the ABI encoding.
      #
      # True for `string`, `bytes`, dynamic arrays, tuples with a dynamic component and fixed arrays of a
      # dynamic element. Indexed event parameters of dynamic type are stored hashed in topics.
      #
      # @return [Boolean]
      def dynamic?
        raw_type == "string" || raw_type == "bytes" || raw_type.end_with?("[]") ||
          (tuple? && components.any?(&:dynamic?)) || (array? && element.dynamic?)
      end

      # The ABI definition of this parameter, rebuilt with String keys.
      #
      # Unnamed parameters get an empty `"name"`, `"components"` is only present for tuples and
      # `"indexed"` only when true; `internalType` is not included.
      #
      # @return [Hash{String => Object}]
      def to_h
        h = { "name" => unnamed? ? "" : name, "type" => raw_type }
        h["components"] = components.map(&:to_h) if tuple?
        h["indexed"] = indexed if indexed
        h
      end
    end
  end
end
