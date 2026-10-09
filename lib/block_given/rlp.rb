# frozen_string_literal: true

module BlockGiven
  # Recursive Length Prefix serialization, the encoding of Ethereum transactions.
  #
  # Items are binary Strings, non-negative Integers (encoded big-endian without leading zeros, 0 being the
  # empty string) and Arrays of items. Decoding returns binary Strings and Arrays only: the caller knows which
  # fields are integers ({.to_int}).
  #
  # @api private
  module Rlp
    module_function

    # Serializes an item.
    #
    # @param item [String, Integer, Array] a binary String, a non-negative Integer or a (nested) Array of them
    # @return [String] the RLP bytes, binary
    # @raise [BlockGiven::InvalidArgumentError] for a negative Integer or an unsupported type
    def encode(item)
      case item
      when Array
        payload = item.map { |element| encode(element) }.join.b
        length_prefix(payload.bytesize, 0xc0) + payload
      when Integer
        raise InvalidArgumentError, "RLP cannot encode negative integer #{item}" if item.negative?

        encode(int_to_bytes(item))
      when String
        bytes = item.b
        return bytes if bytes.bytesize == 1 && bytes.getbyte(0) < 0x80

        length_prefix(bytes.bytesize, 0x80) + bytes
      else raise InvalidArgumentError, "RLP cannot encode #{item.class}"
      end
    end

    # Deserializes exactly one item spanning the whole input.
    #
    # @param bytes [String] RLP bytes, binary
    # @return [String, Array] binary Strings and nested Arrays
    # @raise [BlockGiven::InvalidArgumentError] when the input is truncated, has trailing bytes or is not in
    #   canonical form
    def decode(bytes)
      bytes = bytes.b
      item, consumed = decode_at(bytes, 0)
      raise InvalidArgumentError, "RLP: #{bytes.bytesize - consumed} trailing byte(s)" if consumed != bytes.bytesize

      item
    end

    # Reads a decoded String field as an unsigned big-endian Integer.
    #
    # @param bytes [String] binary String
    # @return [Integer] 0 for the empty String
    # @raise [BlockGiven::InvalidArgumentError] when the value is a list or has leading zero bytes
    def to_int(bytes)
      raise InvalidArgumentError, "RLP: expected an integer, got a list" unless bytes.is_a?(String)
      raise InvalidArgumentError, "RLP: integer with leading zero" if bytes.start_with?("\x00".b)

      bytes.empty? ? 0 : bytes.unpack1("H*").to_i(16)
    end

    # Big-endian bytes of a non-negative Integer, without leading zeros.
    #
    # @param int [Integer]
    # @return [String] binary, empty for 0
    def int_to_bytes(int)
      return "".b if int.zero?

      hex = int.to_s(16)
      [hex.length.odd? ? "0#{hex}" : hex].pack("H*")
    end

    # Prefix announcing a payload length.
    #
    # @param length [Integer] payload size in bytes
    # @param offset [Integer] 0x80 for a String, 0xc0 for a list
    # @return [String] binary prefix
    def length_prefix(length, offset)
      return (offset + length).chr.b if length < 56

      length_bytes = int_to_bytes(length)
      (offset + 55 + length_bytes.bytesize).chr.b + length_bytes
    end

    # Decodes the item starting at a position.
    #
    # @param bytes [String] the whole input, binary
    # @param position [Integer] where the item starts
    # @return [Array(Object, Integer)] the item and the position right after it
    # @raise [BlockGiven::InvalidArgumentError] for truncated or non-canonical input
    def decode_at(bytes, position)
      prefix = bytes.getbyte(position)
      raise InvalidArgumentError, "RLP: unexpected end of input" if prefix.nil?
      return [bytes.byteslice(position, 1), position + 1] if prefix < 0x80

      list = prefix >= 0xc0
      start, length = payload_bounds(bytes, position, prefix - (list ? 0xc0 : 0x80))
      raise InvalidArgumentError, "RLP: unexpected end of input" if start + length > bytes.bytesize
      return [decode_list(bytes, start, start + length), start + length] if list

      payload = bytes.byteslice(start, length)
      raise InvalidArgumentError, "RLP: non-canonical single byte" if length == 1 && payload.getbyte(0) < 0x80

      [payload, start + length]
    end

    # Start and length of the payload following a prefix.
    #
    # @param bytes [String] the whole input, binary
    # @param position [Integer] position of the prefix byte
    # @param short [Integer] prefix minus its type offset (0x80 or 0xc0)
    # @return [Array(Integer, Integer)] payload start and length
    # @raise [BlockGiven::InvalidArgumentError] for a truncated or non-canonical length
    def payload_bounds(bytes, position, short)
      return [position + 1, short] if short < 56

      size = short - 55
      length_bytes = bytes.byteslice(position + 1, size).to_s
      raise InvalidArgumentError, "RLP: unexpected end of input" if length_bytes.bytesize != size

      length = to_int(length_bytes)
      raise InvalidArgumentError, "RLP: non-canonical length" if length < 56

      [position + 1 + size, length]
    end

    # Decodes the items of a list payload.
    #
    # @param bytes [String] the whole input, binary
    # @param position [Integer] start of the list payload
    # @param stop [Integer] end of the list payload
    # @return [Array] the decoded items
    # @raise [BlockGiven::InvalidArgumentError] when an item overflows the list
    def decode_list(bytes, position, stop)
      items = []
      while position < stop
        item, position = decode_at(bytes, position)
        items << item
      end
      raise InvalidArgumentError, "RLP: list item overflows its list" if position != stop

      items
    end
  end
end
