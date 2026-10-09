# frozen_string_literal: true

module BlockGiven
  # EIP-712 typed structured data hashing (`encodeType`, `encodeData`, `hashStruct`, domain separator).
  #
  # The payload is a Hash with `types`, `primaryType`, `domain` and `message`, with Symbol or String keys.
  # When `types` has no `EIP712Domain` entry it is derived from the domain keys present, in the canonical
  # order (`name`, `version`, `chainId`, `verifyingContract`, `salt`), as viem does.
  #
  # Values: integers as Integer, decimal String or `0x` hex String; addresses and `bytes` / `bytesN` as `0x`
  # hex; `string` as text; arrays as Arrays (hashed per the specification, element by element); structs as
  # Hashes keyed by field name.
  #
  # @api private
  module Eip712
    # Domain fields in the order EIP-712 lists them, with their types, used when `EIP712Domain` is omitted.
    DOMAIN_FIELDS = [
      %w[name string], %w[version string], %w[chainId uint256], %w[verifyingContract address], %w[salt bytes32]
    ].freeze

    module_function

    # The digest to sign: keccak256("\x19\x01" || domainSeparator || hashStruct(message)).
    #
    # @param typed_data [Hash] `types`, `primaryType`, `domain` and `message`
    # @return [String] the 32-byte digest, binary
    # @raise [BlockGiven::InvalidArgumentError] when a section is missing, a type is unknown or a value does not
    #   fit its type
    def hash(typed_data)
      data = typed_data.to_h.transform_keys(&:to_s)
      %w[types primaryType domain message].each do |key|
        missing = data[key].nil? || (key != "domain" && data[key].empty?)
        raise InvalidArgumentError, "typed data #{key} is missing" if missing
      end
      domain = data["domain"].transform_keys(&:to_s)
      types = normalize_types(data["types"], domain)
      Crypto::Keccak.digest("\x19\x01".b + hash_struct("EIP712Domain", domain, types) +
                            hash_struct(data["primaryType"].to_s, data["message"], types))
    end

    # keccak256(typeHash || encodeData(fields)) of a struct value.
    #
    # @param type [String] the struct name
    # @param value [Hash] field values by name (Symbol or String keys)
    # @param types [Hash{String => Array<Array(String, String)>}] normalized types: struct name to [name, type]
    # @return [String] 32 bytes, binary
    # @raise [BlockGiven::InvalidArgumentError] when the value is not a Hash or misses a field
    def hash_struct(type, value, types)
      raise InvalidArgumentError, "#{type} expects a Hash, got #{value.inspect}" unless value.is_a?(Hash)

      raise InvalidArgumentError, "unknown EIP-712 type #{type}" unless types.key?(type)

      fields = value.transform_keys(&:to_s)
      encoded = types[type].map do |name, field_type|
        raise InvalidArgumentError, "#{type}.#{name} is missing" unless fields.key?(name)

        encode_field(field_type, fields[name], types)
      end
      Crypto::Keccak.digest(Crypto::Keccak.digest(encode_type(type, types)) + encoded.join)
    end

    # `Name(type1 name1,...)` followed by the referenced structs sorted by name.
    #
    # @param type [String] the struct name
    # @param types [Hash{String => Array<Array(String, String)>}]
    # @return [String]
    def encode_type(type, types)
      ([type] + dependencies(type, types).reject { |t| t == type }.sort).map do |name|
        "#{name}(#{types.fetch(name).map { |field, field_type| "#{field_type} #{field}" }.join(',')})"
      end.join
    end

    # Every struct reachable from a type, the type itself included.
    #
    # @param type [String]
    # @param types [Hash{String => Array<Array(String, String)>}]
    # @param found [Array<String>] accumulator
    # @return [Array<String>]
    def dependencies(type, types, found = [])
      base = type.sub(/(\[\d*\])+\z/, "")
      return found if found.include?(base) || !types.key?(base)

      found << base
      types[base].each { |field| dependencies(field[1], types, found) }
      found
    end

    # The 32-byte encoding of one field value.
    #
    # @param type [String] the field type
    # @param value [Object]
    # @param types [Hash{String => Array<Array(String, String)>}]
    # @return [String] 32 bytes, binary
    # @raise [BlockGiven::InvalidArgumentError] when the value does not fit the type
    def encode_field(type, value, types)
      if (array = type.match(/\A(.+)\[(\d*)\]\z/))
        raise InvalidArgumentError, "#{type} expects an Array, got #{value.inspect}" unless value.is_a?(Array)
        if !array[2].empty? && value.size != array[2].to_i
          raise InvalidArgumentError, "#{type} expects #{array[2]} elements, got #{value.size}"
        end

        return Crypto::Keccak.digest(value.map { |element| encode_field(array[1], element, types) }.join)
      end
      return hash_struct(type, value, types) if types.key?(type)
      return Crypto::Keccak.digest(value.to_s) if type == "string"
      return Crypto::Keccak.digest(hex_bytes(type, value)) if type == "bytes"

      encode_atomic(type, value)
    end

    # The 32-byte word of an atomic value.
    #
    # @param type [String] `uintN`, `intN`, `address`, `bool` or `bytesN`
    # @param value [Object]
    # @return [String] 32 bytes, binary
    # @raise [BlockGiven::InvalidArgumentError] for an unknown type or an out-of-range value
    def encode_atomic(type, value)
      case type
      when /\A(u?)int(\d*)\z/
        bits = ::Regexp.last_match(2).empty? ? 256 : ::Regexp.last_match(2).to_i
        word(integer(type, value), bits, signed: ::Regexp.last_match(1).empty?)
      when "address"
        raise InvalidArgumentError, "invalid address #{value.inspect}" unless Utils.address?(value)

        Utils.hex_to_bin(Utils.pad_hex(value))
      when "bool"
        raise InvalidArgumentError, "bool expects true/false, got #{value.inspect}" unless [true, false].include?(value)

        word(value ? 1 : 0, 8, signed: false)
      when /\Abytes(\d+)\z/
        bytes = hex_bytes(type, value)
        raise InvalidArgumentError, "#{type} value is too long" if bytes.bytesize > ::Regexp.last_match(1).to_i

        bytes.ljust(32, "\x00".b)
      else raise InvalidArgumentError, "unknown EIP-712 type #{type}"
      end
    end

    # @param type [String] for error messages
    # @param value [Integer, String] Integer, decimal String or `0x` hex String
    # @return [Integer]
    # @raise [BlockGiven::InvalidArgumentError] when the value is not an integer
    def integer(type, value)
      return value if value.is_a?(Integer)
      return Utils.hex_to_int(value) if Utils.hex?(value) && value.size > 2
      return Integer(value, 10) if value.is_a?(String)

      raise InvalidArgumentError, "#{type} expects an integer, got #{value.inspect}"
    rescue ::ArgumentError
      raise InvalidArgumentError, "#{type} expects an integer, got #{value.inspect}"
    end

    # A two's complement 32-byte word.
    #
    # @param value [Integer]
    # @param bits [Integer] the type width
    # @param signed [Boolean]
    # @return [String] 32 bytes, binary
    # @raise [BlockGiven::InvalidArgumentError] when the value does not fit
    def word(value, bits, signed:)
      range = signed ? (-(2**(bits - 1))...(2**(bits - 1))) : (0...(2**bits))
      raise InvalidArgumentError, "#{value} does not fit in #{'u' unless signed}int#{bits}" unless range.cover?(value)

      [(value % (2**256)).to_s(16).rjust(64, "0")].pack("H*")
    end

    # @param type [String] for error messages
    # @param value [String] `0x` hex
    # @return [String] the bytes, binary
    # @raise [BlockGiven::InvalidArgumentError] when the value is not hex
    def hex_bytes(type, value)
      raise InvalidArgumentError, "#{type} expects 0x hex: #{value.inspect}" unless value.to_s.match?(/\A0x(\h\h)*\z/)

      Utils.hex_to_bin(value)
    end

    # Struct definitions as `{ "Name" => [[field, type], ...] }`, `EIP712Domain` derived when absent.
    #
    # @param types [Hash] struct name to an Array of `{ name:, type: }`
    # @param domain [Hash{String => Object}] the domain values
    # @return [Hash{String => Array<Array(String, String)>}]
    def normalize_types(types, domain)
      normalized = types.to_h { |name, fields| [name.to_s, fields.map { |f| field_pair(name, f) }] }
      normalized["EIP712Domain"] ||= DOMAIN_FIELDS.select { |name, _type| domain.key?(name) }
      normalized
    end

    # @param struct [String, Symbol] for error messages
    # @param field [Hash] `{ name:, type: }`, Symbol or String keys
    # @return [Array(String, String)] name and type
    # @raise [BlockGiven::InvalidArgumentError] when the definition is malformed
    def field_pair(struct, field)
      field = field.to_h.transform_keys(&:to_s)
      raise InvalidArgumentError, "malformed field in #{struct}: #{field.inspect}" unless field["name"] && field["type"]

      [field["name"].to_s, field["type"].to_s]
    end
  end
end
