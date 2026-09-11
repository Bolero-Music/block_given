# frozen_string_literal: true

module BlockGiven
  module Abi
    # Turns Ruby values into what the ABI encoder expects, and decoded values into idiomatic Ruby.
    #
    # ## Input coercion (Ruby to ABI), per Solidity type
    #
    # - `intN` / `uintN`: `Integer`; a whole `Float`, `BigDecimal` or `Rational` (`1e6` becomes
    #   `1000000`); a decimal String (`"1000000"`) or a `0x` hex String. A fractional or non-finite number
    #   raises `InvalidArgumentError` pointing at `BlockGiven::Utils.parse_units`.
    # - `address`: a `0x` 40-hex-digit String, or any non-String object responding to `#address` (a
    #   {BlockGiven::Wallet}, a {BlockGiven::Contract}). Malformed values raise `InvalidAddressError`.
    # - `bool`: `true` or `false` only (no truthiness).
    # - `string`: anything, converted with `#to_s`.
    # - `bytes` / `bytesN`: a `0x` hex String, or a binary String which is hex-encoded.
    # - tuples: a Hash keyed by component name (Symbol or String, snake_case or camelCase, matched after
    #   `Utils.snake_case`) or an Array in declaration order; components are coerced recursively.
    # - arrays: an Array whose elements are coerced recursively with the element type.
    #
    # ## Output formatting (ABI to Ruby)
    #
    # - `address`: EIP-55 checksummed String.
    # - `bytes` / `bytesN`: `0x` hex String.
    # - `string`: UTF-8 String.
    # - integers and booleans: unchanged (`Integer`, `true` / `false`).
    # - tuples: a Hash with snake_case Symbol keys when every component is named, an Array otherwise.
    # - arrays: an Array of formatted elements.
    #
    # {Function#decode_output} additionally unwraps a single output and returns several as an Array.
    module Coder
      module_function

      # ABI-encodes values for the given parameters after coercing them (see the module documentation).
      #
      # @param params [Array<Parameter>] the parameter types, in order
      # @param values [Array] one Ruby value per parameter
      # @return [String] `0x`-prefixed encoded data (no selector)
      # @raise [BlockGiven::InvalidArgumentError] when the count differs or a value cannot be coerced
      # @raise [BlockGiven::InvalidAddressError] when an address value is malformed
      # @raise [BlockGiven::AbiError] when `Eth::Abi` rejects a coerced value (out of bounds, ...)
      def encode(params, values)
        if params.size != values.size
          raise InvalidArgumentError,
                "expected #{params.size} argument(s), got #{values.size}"
        end

        coerced = params.zip(values).map { |param, value| coerce(value, param) }
        Utils.bin_to_hex(Eth::Abi.encode(params.map(&:type), coerced))
      rescue Eth::Abi::EncodingError, Eth::Abi::ValueOutOfBounds => e
        raise AbiError, "ABI encoding failed: #{e.message}"
      end

      # ABI-decodes data for the given parameters and formats the values (see the module documentation).
      #
      # @param params [Array<Parameter>] the parameter types, in order
      # @param hex [String] `0x`-prefixed encoded data
      # @return [Array] one formatted Ruby value per parameter (empty when `params` is empty, whatever
      #   the data)
      # @raise [BlockGiven::AbiError] when the data is empty (typically no contract at the address) or
      #   `Eth::Abi` cannot decode it
      def decode(params, hex)
        return [] if params.empty?

        data = Utils.strip_hex(hex.to_s)
        raise AbiError, "cannot decode empty data (does the contract exist at this address?)" if data.empty?

        values = Eth::Abi.decode(params.map(&:type), "0x#{data}")
        params.zip(values).map { |param, value| format(value, param) }
      rescue Eth::Abi::DecodingError => e
        raise AbiError, "ABI decoding failed: #{e.message}"
      end

      # Coerces one Ruby value into the encoder input for a parameter (recursing into arrays and tuples).
      #
      # Types without a dedicated rule (`fixed`, `function`...) are passed through unchanged.
      #
      # @api private
      # @param value [Object] the Ruby value
      # @param param [Parameter] the target parameter
      # @return [Object] the encoder-ready value
      # @raise [BlockGiven::InvalidArgumentError] when the value does not fit the type
      # @raise [BlockGiven::InvalidAddressError] when an address is malformed
      def coerce(value, param)
        if param.array?
          raise InvalidArgumentError, "#{param.name} expects an Array, got #{value.inspect}" unless value.is_a?(Array)

          return value.map { |v| coerce(v, param.element) }
        end
        return coerce_tuple(value, param) if param.tuple?

        case param.raw_type
        when /\A(u?int)\d*\z/ then coerce_integer(value, param)
        when "address" then coerce_address(value, param)
        when "bool" then coerce_bool(value, param)
        when "string" then value.to_s
        when /\Abytes\d*\z/ then coerce_bytes(value, param)
        else value
        end
      end

      # Formats one decoded value into idiomatic Ruby for a parameter (recursing into arrays and tuples).
      #
      # @api private
      # @param value [Object] the value returned by `Eth::Abi.decode`
      # @param param [Parameter] the decoded parameter
      # @return [Object] checksummed address, `0x` hex bytes, UTF-8 string, Hash or Array for tuples, or
      #   the value unchanged
      def format(value, param)
        return value.map { |v| format(v, param.element) } if param.array?
        return format_tuple(value, param) if param.tuple?

        case param.raw_type
        when "address" then Utils.checksum_address(value)
        when /\Abytes\d*\z/ then value.is_a?(String) && !Utils.hex?(value) ? Utils.bin_to_hex(value) : value
        when "string" then value.to_s.dup.force_encoding(Encoding::UTF_8)
        else value
        end
      end

      # Coerces a value for an `intN` / `uintN` parameter.
      #
      # @api private
      # @param value [Integer, Float, BigDecimal, Rational, String] an Integer, a whole number, a decimal
      #   String or a `0x` hex String
      # @param param [Parameter]
      # @return [Integer]
      # @raise [BlockGiven::InvalidArgumentError] for fractional or non-finite numbers (use
      #   `Utils.parse_units`), unparsable Strings or any other type
      def coerce_integer(value, param)
        case value
        when Integer then value
        when Float, BigDecimal, Rational
          unless value.finite? && value == value.floor
            raise InvalidArgumentError, "#{param.name}: #{value} is not an integer (use BlockGiven::Utils.parse_units)"
          end

          value.to_i
        when String
          Utils.hex?(value) ? Utils.hex_to_int(value) : Integer(value, 10)
        else raise InvalidArgumentError, "#{param.name} expects an integer, got #{value.inspect}"
        end
      rescue ::ArgumentError
        raise InvalidArgumentError, "#{param.name} expects an integer, got #{value.inspect}"
      end

      # Coerces a value for an `address` parameter.
      #
      # @api private
      # @param value [String, #address] a `0x` hex address or a non-String object responding to `#address`
      # @param param [Parameter]
      # @return [String] the address as given (not checksummed)
      # @raise [BlockGiven::InvalidAddressError] when the resulting value is not a 20-byte hex address
      def coerce_address(value, param)
        value = value.address if value.respond_to?(:address) && !value.is_a?(String)
        raise InvalidAddressError, "#{param.name}: invalid address #{value.inspect}" unless Utils.address?(value)

        value
      end

      # Coerces a value for a `bool` parameter; only `true` and `false` are accepted.
      #
      # @api private
      # @param value [Boolean]
      # @param param [Parameter]
      # @return [Boolean]
      # @raise [BlockGiven::InvalidArgumentError] for anything else (no truthiness)
      def coerce_bool(value, param)
        return value if [true, false].include?(value)

        raise InvalidArgumentError, "#{param.name} expects true/false, got #{value.inspect}"
      end

      # Coerces a value for a `bytes` / `bytesN` parameter.
      #
      # @api private
      # @param value [String] a `0x` hex String (kept) or a binary String (hex-encoded)
      # @param param [Parameter]
      # @return [String] `0x` hex
      # @raise [BlockGiven::InvalidArgumentError] when the value is not a String
      def coerce_bytes(value, param)
        raise InvalidArgumentError, "#{param.name} expects a hex or binary String" unless value.is_a?(String)

        Utils.hex?(value) ? value : Utils.bin_to_hex(value)
      end

      # Coerces a value for a tuple parameter into an Array of coerced components.
      #
      # @api private
      # @param value [Hash, Array] components by name (see {.tuple_values_from_hash}) or in declaration
      #   order
      # @param param [Parameter] a tuple parameter
      # @return [Array] coerced component values, in declaration order
      # @raise [BlockGiven::InvalidArgumentError] when the value is neither a Hash nor an Array, when the
      #   number of values differs from the number of components, or when a field is missing
      def coerce_tuple(value, param)
        values =
          case value
          when Hash then tuple_values_from_hash(value, param)
          when Array then value
          else raise InvalidArgumentError, "#{param.name} expects a Hash or Array for tuple #{param.type}"
          end
        if values.size != param.components.size
          raise InvalidArgumentError, "#{param.name}: tuple #{param.type} expects #{param.components.size} values"
        end

        param.components.zip(values).map { |component, v| coerce(v, component) }
      end

      # Orders the values of a tuple Hash by component; keys match component names after `Utils.snake_case`
      # (Symbol or String, snake_case or camelCase). Extra keys are ignored.
      #
      # @api private
      # @param hash [Hash] component values by name
      # @param param [Parameter] a tuple parameter
      # @return [Array] values in component declaration order
      # @raise [BlockGiven::InvalidArgumentError] when a component has no matching key
      def tuple_values_from_hash(hash, param)
        lookup = hash.transform_keys { |k| Utils.snake_case(k) }
        param.components.map do |component|
          key = Utils.snake_case(component.name)
          raise InvalidArgumentError, "#{param.name}: missing tuple field #{component.name}" unless lookup.key?(key)

          lookup[key]
        end
      end

      # Formats a decoded tuple: a Hash with snake_case Symbol keys when every component is named, an
      # Array otherwise.
      #
      # @api private
      # @param values [Array] decoded component values
      # @param param [Parameter] a tuple parameter
      # @return [Hash{Symbol => Object}, Array]
      def format_tuple(values, param)
        formatted = param.components.zip(values).map { |component, v| format(v, component) }
        return formatted if param.components.any?(&:unnamed?)

        param.components.map(&:ruby_name).zip(formatted).to_h
      end
    end
  end
end
