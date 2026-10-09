# frozen_string_literal: true

module BlockGiven
  module Abi
    # A parsed Solidity ABI type (`uint256`, `bytes32[2][]`, `(uint256,(bool,bytes))[]`), as the codec needs it:
    # its base type, its size, its array dimensions and its tuple components.
    #
    # @api private
    class Type
      # @return [String] `uint`, `int`, `address`, `bool`, `bytes`, `string` or `tuple`
      attr_reader :base
      # @return [Integer, nil] bits of an integer, bytes of a `bytesN`, nil otherwise
      attr_reader :size
      # @return [Array<Integer, nil>] array dimensions, innermost first; nil marks a dynamic `[]`
      attr_reader :dimensions
      # @return [Array<Type>] tuple components, empty for other types
      attr_reader :components

      # Parses a canonical type string, with tuples written `(a,b)` or `tuple(a,b)`.
      #
      # @param type [String]
      # @return [Type]
      # @raise [BlockGiven::AbiError] when the type is malformed or not supported (`fixed`, `function`)
      def self.parse(type)
        type = type.to_s.strip
        type = type.delete_prefix("tuple") if type.start_with?("tuple(")
        return parse_tuple(type) if type.start_with?("(")

        match = type.match(/\A([a-z]+)(\d*)((?:\[\d*\])*)\z/)
        raise AbiError, "unsupported ABI type #{type.inspect}" unless match

        new(*elementary(match[1], match[2], type), dimensions(match[3]))
      end

      # Parses a tuple type and its trailing dimensions.
      #
      # @param type [String] starting with `(`
      # @return [Type]
      # @raise [BlockGiven::AbiError] when the parentheses do not balance
      def self.parse_tuple(type)
        depth = 0
        parts = [+""]
        type.each_char.with_index do |char, index|
          depth += { "(" => 1, ")" => -1 }.fetch(char, 0)
          if depth.zero?
            raise AbiError, "unsupported ABI type #{type.inspect}" unless type[(index + 1)..].match?(/\A(\[\d*\])*\z/)

            components = parts.first.empty? && parts.size == 1 ? [] : parts.map { |part| parse(part) }
            return new("tuple", nil, dimensions(type[(index + 1)..]), components)
          end
          next if depth == 1 && char == "("

          depth == 1 && char == "," ? parts << +"" : parts.last << char
        end
        raise AbiError, "unsupported ABI type #{type.inspect}"
      end

      # Validates an elementary base type and its size suffix.
      #
      # @param base [String]
      # @param suffix [String] digits, possibly empty
      # @param type [String] the full type, for error messages
      # @return [Array(String, Integer)] base and size (nil when the type takes none)
      # @raise [BlockGiven::AbiError] for an unknown base or an invalid size
      def self.elementary(base, suffix, type)
        size = suffix.empty? ? nil : suffix.to_i
        valid =
          case base
          when "uint", "int"
            size ||= 256
            size.between?(8, 256) && (size % 8).zero?
          when "bytes" then size.nil? || size.between?(1, 32)
          when "address", "bool", "string" then size.nil?
          else false
          end
        raise AbiError, "unsupported ABI type #{type.inspect}" unless valid

        [base, size]
      end

      # @param suffix [String] e.g. `[2][]`
      # @return [Array<Integer, nil>]
      def self.dimensions(suffix) = suffix.scan(/\[(\d*)\]/).map { |(digits)| digits.empty? ? nil : digits.to_i }

      private_class_method :parse_tuple, :elementary, :dimensions

      # @param base [String]
      # @param size [Integer, nil]
      # @param dimensions [Array<Integer, nil>]
      # @param components [Array<Type>]
      def initialize(base, size, dimensions, components = [])
        @base = base
        @size = size
        @dimensions = dimensions
        @components = components
      end

      # @return [Boolean] whether the type is an array
      def array? = !dimensions.empty?

      # @return [Type] the element type of an array (outermost dimension removed)
      def element = Type.new(base, size, dimensions[0...-1], components)

      # @return [Integer, nil] the outermost array length, nil for a dynamic array
      def length = dimensions.last

      # Whether the encoding is dynamic (stored behind an offset).
      #
      # @return [Boolean]
      def dynamic?
        return @dynamic unless @dynamic.nil?

        @dynamic =
          if array? then length.nil? || element.dynamic?
          elsif base == "tuple" then components.any?(&:dynamic?)
          else base == "string" || (base == "bytes" && size.nil?)
          end
      end

      # Bytes taken by a static value in the head of its enclosing sequence (32 for dynamic types: the offset).
      #
      # @return [Integer]
      def head_size
        return 32 if dynamic?
        return length * element.head_size if array?
        return components.sum(&:head_size) if base == "tuple"

        32
      end

      # @return [String] the canonical type, e.g. `(uint256,bytes)[]`
      def to_s
        core = base == "tuple" ? "(#{components.join(',')})" : "#{base}#{size}"
        core + dimensions.map { |d| "[#{d}]" }.join
      end
    end
  end
end
