# frozen_string_literal: true

module BlockGiven
  module Abi
    module Codec
      # The decoding half of {Codec}: reads heads, follows offsets, and checks every read against the data size so
      # that malformed data raises instead of returning garbage.
      #
      # @api private
      module Decoder
        module_function

        # Decodes a sequence whose head starts at `start`; offsets of dynamic values are relative to `start`.
        #
        # @param types [Array<Type>]
        # @param data [String] the whole encoding, binary
        # @param start [Integer]
        # @return [Array]
        # @raise [BlockGiven::AbiDecodingError] when data is missing
        def decode_sequence(types, data, start)
          position = start
          types.map do |type|
            value =
              if type.dynamic?
                decode_value(type, data, start + read_offset(data, position))
              else
                decode_value(type, data, position)
              end
            position += type.head_size
            value
          end
        end

        # Decodes one value encoded at a position.
        #
        # @param type [Type]
        # @param data [String] binary
        # @param position [Integer]
        # @return [Object]
        # @raise [BlockGiven::AbiDecodingError] when data is missing
        def decode_value(type, data, position)
          return decode_array(type, data, position) if type.array?

          case type.base
          when "tuple" then decode_sequence(type.components, data, position)
          when "uint" then read_uint(data, position)
          when "int"
            value = read_uint(data, position)
            value >= 2**255 ? value - (2**256) : value
          when "address" then Utils.bin_to_hex(read(data, position + 12, 20))
          when "bool" then read_uint(data, position) == 1
          when "string" then decode_bytes(data, position).force_encoding(Encoding::UTF_8)
          else type.size ? read(data, position, type.size) : decode_bytes(data, position)
          end
        end

        # @param type [Type] an array type
        # @param data [String] binary
        # @param position [Integer]
        # @return [Array]
        # @raise [BlockGiven::AbiDecodingError] when the announced length exceeds the data
        def decode_array(type, data, position)
          return decode_sequence(Array.new(type.length, type.element), data, position) if type.length

          count = read_uint(data, position)
          if count * [type.element.head_size, 1].max > data.bytesize - position - 32
            raise AbiDecodingError, "array length #{count} exceeds the data"
          end

          decode_sequence(Array.new(count, type.element), data, position + 32)
        end

        # @param data [String] binary
        # @param position [Integer] position of the length word
        # @return [String] the bytes after the length word, binary
        # @raise [BlockGiven::AbiDecodingError] when the data is shorter than the announced length
        def decode_bytes(data, position) = read(data, position + 32, read_uint(data, position))

        # @param data [String] binary
        # @param position [Integer]
        # @return [Integer] an offset, bounded by the data size
        # @raise [BlockGiven::AbiDecodingError] when the offset points outside of the data
        def read_offset(data, position)
          offset = read_uint(data, position)
          raise AbiDecodingError, "offset #{offset} points outside of the data" if offset > data.bytesize

          offset
        end

        # @param data [String] binary
        # @param position [Integer]
        # @return [Integer] the unsigned 32-byte word at the position
        # @raise [BlockGiven::AbiDecodingError] when fewer than 32 bytes remain
        def read_uint(data, position) = read(data, position, 32).unpack1("H*").to_i(16)

        # @param data [String] binary
        # @param position [Integer]
        # @param length [Integer]
        # @return [String] exactly `length` bytes, binary
        # @raise [BlockGiven::AbiDecodingError] when the data is too short
        def read(data, position, length)
          if position.negative? || length.negative? || position + length > data.bytesize
            raise AbiDecodingError, "not enough data: needed #{position + length} bytes, got #{data.bytesize}"
          end

          data.byteslice(position, length)
        end
      end
    end
  end
end
