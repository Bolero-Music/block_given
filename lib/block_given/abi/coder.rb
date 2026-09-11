# frozen_string_literal: true

module BlockGiven
  module Abi
    # Turns Ruby values into what the ABI encoder expects, and decoded values
    # into idiomatic Ruby (checksummed addresses, hex bytes, named tuples as Hash).
    module Coder
      module_function

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

      def decode(params, hex)
        return [] if params.empty?

        data = Utils.strip_hex(hex.to_s)
        raise AbiError, "cannot decode empty data (does the contract exist at this address?)" if data.empty?

        values = Eth::Abi.decode(params.map(&:type), "0x#{data}")
        params.zip(values).map { |param, value| format(value, param) }
      rescue Eth::Abi::DecodingError => e
        raise AbiError, "ABI decoding failed: #{e.message}"
      end

      # Ruby -> encoder input.
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

      # Decoded value -> Ruby.
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

      def coerce_address(value, param)
        value = value.address if value.respond_to?(:address) && !value.is_a?(String)
        raise InvalidAddressError, "#{param.name}: invalid address #{value.inspect}" unless Utils.address?(value)

        value
      end

      def coerce_bool(value, param)
        return value if [true, false].include?(value)

        raise InvalidArgumentError, "#{param.name} expects true/false, got #{value.inspect}"
      end

      def coerce_bytes(value, param)
        raise InvalidArgumentError, "#{param.name} expects a hex or binary String" unless value.is_a?(String)

        Utils.hex?(value) ? value : Utils.bin_to_hex(value)
      end

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

      def tuple_values_from_hash(hash, param)
        lookup = hash.transform_keys { |k| Utils.snake_case(k) }
        param.components.map do |component|
          key = Utils.snake_case(component.name)
          raise InvalidArgumentError, "#{param.name}: missing tuple field #{component.name}" unless lookup.key?(key)

          lookup[key]
        end
      end

      def format_tuple(values, param)
        formatted = param.components.zip(values).map { |component, v| format(v, component) }
        return formatted if param.components.any?(&:unnamed?)

        param.components.map(&:ruby_name).zip(formatted).to_h
      end
    end
  end
end
