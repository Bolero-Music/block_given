# frozen_string_literal: true

module BlockGiven
  module Abi
    # The Solidity contract ABI encoding: heads and tails, offsets, two's complement integers, padded bytes.
    #
    # Works on already coerced values (see {Coder} for the Ruby-facing layer): Integers for `intN` / `uintN`,
    # `0x` hex Strings for `address`, `0x` hex or binary Strings for `bytes` / `bytesN`, Strings for `string`,
    # `true` / `false`, and Arrays for arrays and tuples. Decoding returns the same shapes, with lowercase
    # addresses and binary Strings for bytes.
    #
    # @api private
    module Codec
      module_function

      # Encodes values for a list of types, as function arguments are.
      #
      # @param types [Array<String, Type>] canonical types
      # @param values [Array] one value per type
      # @return [String] the encoding, binary
      # @raise [BlockGiven::AbiEncodingError] when a value does not fit its type
      # @raise [BlockGiven::AbiError] when a type is not supported
      def encode(types, values)
        types = types.map { |type| type.is_a?(Type) ? type : Type.parse(type) }
        raise AbiEncodingError, "expected #{types.size} value(s), got #{values.size}" if types.size != values.size

        encode_sequence(types, values)
      end

      # Decodes data produced for a list of types.
      #
      # @param types [Array<String, Type>] canonical types
      # @param data [String] the encoding, binary
      # @return [Array] one value per type
      # @raise [BlockGiven::AbiDecodingError] when the data is too short or an offset points outside of it
      # @raise [BlockGiven::AbiError] when a type is not supported
      def decode(types, data)
        types = types.map { |type| type.is_a?(Type) ? type : Type.parse(type) }
        Decoder.decode_sequence(types, data.b, 0)
      end

      # Encodes a sequence (arguments, tuple components or array elements): static values in place, dynamic
      # ones behind an offset relative to the start of the sequence.
      #
      # @param types [Array<Type>]
      # @param values [Array]
      # @return [String] binary
      def encode_sequence(types, values)
        offset = types.sum(&:head_size)
        heads = +"".b
        tails = +"".b
        types.zip(values).each do |type, value|
          encoded = encode_value(type, value)
          if type.dynamic?
            heads << uint_word(offset + tails.bytesize)
            tails << encoded
          else
            heads << encoded
          end
        end
        heads + tails
      end

      # Encodes one value.
      #
      # @param type [Type]
      # @param value [Object]
      # @return [String] binary
      # @raise [BlockGiven::AbiEncodingError] when the value does not fit the type
      def encode_value(type, value)
        return encode_array(type, value) if type.array?

        case type.base
        when "tuple"
          unless value.is_a?(Array) && value.size == type.components.size
            raise AbiEncodingError, "#{type} expects an Array of #{type.components.size} values, got #{value.inspect}"
          end

          encode_sequence(type.components, value)
        when "uint", "int" then encode_integer(type, value)
        when "address" then encode_address(value)
        when "bool"
          raise AbiEncodingError, "bool expects true/false, got #{value.inspect}" unless [true, false].include?(value)

          uint_word(value ? 1 : 0)
        when "string" then encode_bytes(string_bytes(value))
        else type.size ? encode_fixed_bytes(type, value) : encode_bytes(binary(type, value))
        end
      end

      # @param type [Type] an array type
      # @param value [Array]
      # @return [String] binary: the length (dynamic arrays only) then the elements as a sequence
      # @raise [BlockGiven::AbiEncodingError] when the value is not an Array of the declared length
      def encode_array(type, value)
        raise AbiEncodingError, "#{type} expects an Array, got #{value.inspect}" unless value.is_a?(Array)
        if type.length && value.size != type.length
          raise AbiEncodingError, "#{type} expects #{type.length} elements, got #{value.size}"
        end

        elements = encode_sequence(Array.new(value.size, type.element), value)
        type.length ? elements : uint_word(value.size) + elements
      end

      # @param type [Type] `intN` or `uintN`
      # @param value [Integer]
      # @return [String] the two's complement 32-byte word, binary
      # @raise [BlockGiven::AbiEncodingError] when the value is not an Integer or is out of bounds
      def encode_integer(type, value)
        raise AbiEncodingError, "#{type} expects an Integer, got #{value.inspect}" unless value.is_a?(Integer)

        range = type.base == "int" ? (-(2**(type.size - 1))...(2**(type.size - 1))) : (0...(2**type.size))
        raise AbiEncodingError, "value #{value} is out of bounds for #{type}" unless range.cover?(value)

        uint_word(value % (2**256))
      end

      # @param value [String] `0x` hex address
      # @return [String] the left-padded word, binary
      # @raise [BlockGiven::AbiEncodingError] when the value is not a 20-byte hex address
      def encode_address(value)
        raise AbiEncodingError, "invalid address #{value.inspect}" unless Utils.address?(value)

        Utils.hex_to_bin(Utils.pad_hex(value))
      end

      # @param type [Type] `bytesN`
      # @param value [String] `0x` hex or binary, at most N bytes
      # @return [String] the right-padded word, binary
      # @raise [BlockGiven::AbiEncodingError] when the value is longer than N bytes
      def encode_fixed_bytes(type, value)
        bytes = binary(type, value)
        raise AbiEncodingError, "#{bytes.bytesize} bytes are out of bounds for #{type}" if bytes.bytesize > type.size

        bytes.ljust(32, "\x00".b)
      end

      # @param bytes [String] binary
      # @return [String] the length word, then the bytes right-padded to a multiple of 32, binary
      def encode_bytes(bytes)
        uint_word(bytes.bytesize) + bytes.ljust(((bytes.bytesize + 31) / 32) * 32, "\x00".b)
      end

      # @param type [Type] for error messages
      # @param value [String] `0x` hex (decoded) or any other String (taken as raw bytes)
      # @return [String] binary
      # @raise [BlockGiven::AbiEncodingError] when the value is not a String or is odd-length hex
      def binary(type, value)
        raise AbiEncodingError, "#{type} expects a String, got #{value.inspect}" unless value.is_a?(String)
        return value.b unless Utils.hex?(value)
        raise AbiEncodingError, "#{type} expects an even number of hex digits" if value.size.odd?

        Utils.hex_to_bin(value)
      end

      # @param value [String]
      # @return [String] the UTF-8 bytes, binary
      # @raise [BlockGiven::AbiEncodingError] when the value is not a String
      def string_bytes(value)
        raise AbiEncodingError, "string expects a String, got #{value.inspect}" unless value.is_a?(String)

        value.encode(Encoding::UTF_8).b
      end

      # @param value [Integer] 0 to 2**256 - 1
      # @return [String] 32 big-endian bytes, binary
      def uint_word(value) = [value.to_s(16).rjust(64, "0")].pack("H*")
    end
  end
end
