# frozen_string_literal: true

require "bigdecimal"
require "bigdecimal/util"

module BlockGiven
  # Stateless helpers, mirroring viem's `utils` (parseUnits, formatUnits, keccak256, ...).
  module Utils
    module_function

    ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
    BLOCK_TAGS = %w[latest earliest pending safe finalized].freeze

    def hex?(value)
      value.is_a?(String) && value.match?(/\A0x[0-9a-fA-F]*\z/)
    end

    def prefix_hex(hex)
      hex.start_with?("0x") ? hex : "0x#{hex}"
    end

    def strip_hex(hex)
      hex.start_with?("0x") ? hex[2..] : hex
    end

    # Integer -> "0x1a" (no leading zeros, as JSON-RPC QUANTITY expects).
    def to_hex(value)
      case value
      when Integer then "0x#{value.to_s(16)}"
      when String then prefix_hex(value)
      else raise InvalidArgumentError, "cannot convert #{value.inspect} to hex"
      end
    end

    def hex_to_int(hex)
      return nil if hex.nil?
      return hex if hex.is_a?(Integer)

      Integer(strip_hex(hex), 16)
    end

    def hex_to_bin(hex)
      [strip_hex(hex)].pack("H*")
    end

    def bin_to_hex(bin)
      "0x#{bin.unpack1('H*')}"
    end

    # Left-pads a hex value to 32 bytes (used for event topics).
    def pad_hex(hex, bytes: 32)
      "0x#{strip_hex(hex).rjust(bytes * 2, '0')}"
    end

    # keccak256 of raw bytes (or of the bytes represented by a 0x hex string).
    def keccak256(data)
      bytes = hex?(data) ? hex_to_bin(data) : data.to_s
      bin_to_hex(Eth::Util.keccak256(bytes))
    end

    def address?(value)
      value.is_a?(String) && value.match?(/\A0x[0-9a-fA-F]{40}\z/)
    end

    def checksum_address(value)
      value = value.address if value.respond_to?(:address) && !value.is_a?(String)
      raise InvalidAddressError, "invalid address: #{value.inspect}" unless address?(value)

      Eth::Address.new(value).checksummed
    end

    def same_address?(a, b)
      a.to_s.downcase == b.to_s.downcase
    end

    # "1.5", 6 -> 1_500_000. Accepts String, Integer, Float, Rational, BigDecimal.
    def parse_units(value, decimals)
      decimal = to_decimal(value)
      scaled = decimal * (BigDecimal(10)**decimals)
      raise InvalidArgumentError, "#{value} has more than #{decimals} decimals" unless scaled.frac.zero?

      scaled.to_i
    end

    # 1_500_000, 6 -> "1.5"
    def format_units(value, decimals)
      decimal = BigDecimal(value.to_i) / (BigDecimal(10)**decimals)
      str = decimal.to_s("F")
      str = str.sub(/\.?0+\z/, "") if str.include?(".")
      str
    end

    def parse_ether(value) = parse_units(value, 18)
    def format_ether(value) = format_units(value, 18)
    def parse_gwei(value) = parse_units(value, 9)
    def format_gwei(value) = format_units(value, 9)

    def to_decimal(value)
      case value
      when BigDecimal then value
      when Integer then BigDecimal(value)
      when Float then BigDecimal(value.to_s)
      when Rational then BigDecimal(value, 40)
      when String then BigDecimal(value.strip)
      else raise InvalidArgumentError, "cannot convert #{value.inspect} to a decimal"
      end
    rescue ::ArgumentError
      raise InvalidArgumentError, "cannot convert #{value.inspect} to a decimal"
    end

    # Accepts an Integer, a hex QUANTITY or a block tag (:latest, "pending", ...).
    def block_tag(value)
      case value
      when nil then "latest"
      when Integer then to_hex(value)
      when Symbol then block_tag(value.to_s)
      when String
        return value if hex?(value) || BLOCK_TAGS.include?(value)

        raise InvalidArgumentError, "invalid block tag: #{value.inspect}"
      else raise InvalidArgumentError, "invalid block: #{value.inspect}"
      end
    end

    def snake_case(name)
      name.to_s
          .sub(/\A_+/, "")
          .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
          .gsub(/([a-z\d])([A-Z])/, '\1_\2')
          .tr("-", "_")
          .downcase
    end
  end
end
