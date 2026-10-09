# frozen_string_literal: true

require "bigdecimal"
require "bigdecimal/util"

module BlockGiven
  # Stateless helpers mirroring viem's `utils`: hex and byte conversion, keccak256, addresses, unit parsing and
  # formatting, block tags and name casing.
  #
  # Every method is a module function (`BlockGiven::Utils.parse_units(...)`). Hex values are `0x`-prefixed
  # Strings, amounts are Integers in the smallest unit (wei for ETH), and addresses come back EIP-55
  # checksummed.
  #
  # @example
  #   BlockGiven::Utils.parse_units("1.5", 6)   # => 1_500_000
  #   BlockGiven::Utils.format_ether(10**18)     # => "1"
  #   BlockGiven::Utils.checksum_address("0xd8da6bf26964af9d7eed9e03e53415d37aa96045")
  #   # => "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
  module Utils
    module_function

    # The zero address (`address(0)`): 20 zero bytes, used as the `from` of mints and the `to` of burns.
    ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
    # Block tags JSON-RPC accepts in place of a block number (see {.block_tag}).
    BLOCK_TAGS = %w[latest earliest pending safe finalized].freeze

    # Whether a value is a `0x`-prefixed hexadecimal String (the empty `"0x"` counts).
    #
    # @param value [Object]
    # @return [Boolean]
    def hex?(value)
      value.is_a?(String) && value.match?(/\A0x[0-9a-fA-F]*\z/)
    end

    # Add the `0x` prefix to a hex string when it is missing.
    #
    # @param hex [String]
    # @return [String]
    def prefix_hex(hex)
      hex.start_with?("0x") ? hex : "0x#{hex}"
    end

    # Remove the `0x` prefix from a hex string when it is present.
    #
    # @param hex [String]
    # @return [String]
    def strip_hex(hex)
      hex.start_with?("0x") ? hex[2..] : hex
    end

    # Convert an Integer to a JSON-RPC QUANTITY (`26` -> `"0x1a"`, no leading zeros); Strings only get prefixed.
    #
    # @param value [Integer, String] Integer to encode, or hex String to `0x`-prefix
    # @return [String]
    # @raise [BlockGiven::InvalidArgumentError] for any other type
    def to_hex(value)
      case value
      when Integer then "0x#{value.to_s(16)}"
      when String then prefix_hex(value)
      else raise InvalidArgumentError, "cannot convert #{value.inspect} to hex"
      end
    end

    # Convert a hex QUANTITY to an Integer.
    #
    # @param hex [String, Integer, nil] hex String with or without `0x`; Integers pass through
    # @return [Integer, nil] nil when `hex` is nil
    def hex_to_int(hex)
      return nil if hex.nil?
      return hex if hex.is_a?(Integer)

      Integer(strip_hex(hex), 16)
    end

    # Decode a hex string into binary bytes.
    #
    # @param hex [String] hex with or without `0x`
    # @return [String] binary (ASCII-8BIT) String
    def hex_to_bin(hex)
      [strip_hex(hex)].pack("H*")
    end

    # Encode binary bytes as a `0x` hex string.
    #
    # @param bin [String] binary String
    # @return [String] lowercase `0x` hex
    def bin_to_hex(bin)
      "0x#{bin.unpack1('H*')}"
    end

    # Left-pad a hex value with zeros to a fixed byte length, 32 bytes by default as event topics require.
    #
    # @param hex [String] hex with or without `0x`
    # @param bytes [Integer] target length in bytes
    # @return [String] `0x` followed by `bytes * 2` hex chars (longer inputs are returned with only the prefix
    #   normalised)
    def pad_hex(hex, bytes: 32)
      "0x#{strip_hex(hex).rjust(bytes * 2, '0')}"
    end

    # keccak256 of raw bytes, or of the bytes a `0x` hex string represents.
    #
    # @param data [String] `0x` hex is decoded first; any other String is hashed as-is (e.g. an event signature)
    # @return [String] 32-byte digest as a `0x` hex string
    # @example
    #   BlockGiven::Utils.keccak256("Transfer(address,address,uint256)")
    #   # => "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
    def keccak256(data)
      bytes = hex?(data) ? hex_to_bin(data) : data.to_s
      bin_to_hex(Eth::Util.keccak256(bytes))
    end

    # Whether a value is a 20-byte hex address (`0x` + 40 hex chars); the EIP-55 checksum is not verified.
    #
    # @param value [Object]
    # @return [Boolean]
    def address?(value)
      value.is_a?(String) && value.match?(/\A0x[0-9a-fA-F]{40}\z/)
    end

    # Return the EIP-55 checksummed form of an address.
    #
    # @param value [String, #address] hex address in any casing, or an object responding to `address` such as a
    #   {Wallet} or a {Contract}
    # @return [String] checksummed `0x` address
    # @raise [BlockGiven::InvalidAddressError] when the value is not a 20-byte hex address
    def checksum_address(value)
      value = value.address if value.respond_to?(:address) && !value.is_a?(String)
      raise InvalidAddressError, "invalid address: #{value.inspect}" unless address?(value)

      Eth::Address.new(value).checksummed
    end

    # Compare two addresses ignoring checksum casing.
    #
    # @param a [String, #to_s]
    # @param b [String, #to_s]
    # @return [Boolean]
    def same_address?(a, b)
      a.to_s.downcase == b.to_s.downcase
    end

    # Convert a human readable amount to an Integer in the smallest unit (viem's `parseUnits`).
    #
    # @param value [String, Integer, Float, Rational, BigDecimal] decimal amount; Strings avoid float rounding
    # @param decimals [Integer] decimals of the token (18 for ETH, 6 for USDC)
    # @return [Integer] amount in the smallest unit
    # @raise [BlockGiven::InvalidArgumentError] when the value is not a decimal or has more than `decimals`
    #   fractional digits
    # @example
    #   BlockGiven::Utils.parse_units("1.5", 6)       # => 1_500_000
    #   BlockGiven::Utils.parse_units("0.000001", 18) # => 1_000_000_000_000
    #   BlockGiven::Utils.parse_units("1.0000001", 6) # raises BlockGiven::InvalidArgumentError
    def parse_units(value, decimals)
      decimal = to_decimal(value)
      scaled = decimal * (BigDecimal(10)**decimals)
      raise InvalidArgumentError, "#{value} has more than #{decimals} decimals" unless scaled.frac.zero?

      scaled.to_i
    end

    # Format an Integer amount in the smallest unit as a decimal String (viem's `formatUnits`).
    #
    # Trailing zeros and a trailing dot are removed, so `1_000_000` with 6 decimals gives `"1"`, not `"1.0"`.
    #
    # @param value [Integer, #to_i] amount in the smallest unit
    # @param decimals [Integer] decimals of the token
    # @return [String] plain decimal notation, never scientific
    # @example
    #   BlockGiven::Utils.format_units(1_500_000, 6) # => "1.5"
    def format_units(value, decimals)
      decimal = BigDecimal(value.to_i) / (BigDecimal(10)**decimals)
      str = decimal.to_s("F")
      str = str.sub(/\.?0+\z/, "") if str.include?(".")
      str
    end

    # {.parse_units} with 18 decimals: ether to wei.
    #
    # @param value [String, Integer, Float, Rational, BigDecimal] amount in ether
    # @return [Integer] wei
    # @raise [BlockGiven::InvalidArgumentError] see {.parse_units}
    def parse_ether(value) = parse_units(value, 18)

    # {.format_units} with 18 decimals: wei to ether.
    #
    # @param value [Integer, #to_i] wei
    # @return [String] ether
    def format_ether(value) = format_units(value, 18)

    # {.parse_units} with 9 decimals: gwei to wei (handy for gas prices).
    #
    # @param value [String, Integer, Float, Rational, BigDecimal] amount in gwei
    # @return [Integer] wei
    # @raise [BlockGiven::InvalidArgumentError] see {.parse_units}
    def parse_gwei(value) = parse_units(value, 9)

    # {.format_units} with 9 decimals: wei to gwei.
    #
    # @param value [Integer, #to_i] wei
    # @return [String] gwei
    def format_gwei(value) = format_units(value, 9)

    # Convert a numeric value to a BigDecimal without floating point surprises.
    #
    # Floats go through their String form, Rationals get 40 significant digits, Strings are stripped first.
    #
    # @api private
    # @param value [BigDecimal, Integer, Float, Rational, String]
    # @return [BigDecimal]
    # @raise [BlockGiven::InvalidArgumentError] for other types or Strings BigDecimal cannot parse
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

    # Build the block parameter of a JSON-RPC call from an Integer, a hex QUANTITY or a block tag.
    #
    # @param value [Integer, String, Symbol, nil] block number, `0x` hex QUANTITY, or one of {BLOCK_TAGS} as
    #   String or Symbol; nil means `"latest"`
    # @return [String] hex QUANTITY or tag, ready to be sent as RPC parameter
    # @raise [BlockGiven::InvalidArgumentError] for an unknown tag or an unsupported type
    # @example
    #   BlockGiven::Utils.block_tag(nil)        # => "latest"
    #   BlockGiven::Utils.block_tag(18_000_000) # => "0x112a880"
    #   BlockGiven::Utils.block_tag(:finalized) # => "finalized"
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

    # Convert a camelCase or PascalCase name to snake_case, as used for ABI names and RPC keys.
    #
    # Leading underscores are dropped (`"_owner"` -> `"owner"`), acronyms are split (`"ERC20Token"` ->
    # `"erc20_token"`) and dashes become underscores.
    #
    # @param name [String, Symbol]
    # @return [String]
    # @example
    #   BlockGiven::Utils.snake_case("maxFeePerGas") # => "max_fee_per_gas"
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
