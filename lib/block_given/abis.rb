# frozen_string_literal: true

module BlockGiven
  # Standard token interfaces shipped with the gem as plain ABI arrays (the same shape as a parsed
  # JSON ABI): ERC20, ERC721, ERC1155 and ERC4626, with their ERC-6093 custom errors.
  #
  #   class Usdc < BlockGiven::Contract
  #     abi :erc20                        # or: abi BlockGiven::Abis::ERC20
  #     address "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
  #   end
  #
  # Your own contracts keep their ABIs in your application (see Contract.abi_file).
  module Abis
    # @return [Array<Symbol>] the names of the shipped standards, as {fetch} and `Contract.abi` accept them
    NAMES = %i[erc20 erc721 erc1155 erc4626].freeze

    class << self
      # Shipped ABI by name: `:erc20`, `"ERC721"`, `"erc-1155"` all work.
      #
      # @param name [Symbol, String] the standard's name, case, dashes and underscores ignored
      # @return [Array<Hash>] the deep-frozen JSON-ABI definitions of the standard
      # @raise [BlockGiven::AbiError] when no shipped standard has that name
      # @example
      #   BlockGiven::Abis.fetch("ERC-721") # => [{"type"=>"function", "name"=>"balanceOf", ...}, ...]
      def fetch(name)
        key = name.to_s.downcase.delete("-_").to_sym
        raise AbiError, "unknown ABI #{name.inspect} (shipped: #{NAMES.join(', ')})" unless NAMES.include?(key)

        const_get(key.to_s.upcase, false)
      end

      # The names of the shipped standards.
      #
      # @return [Array<Symbol>] {NAMES}
      # @example
      #   BlockGiven::Abis.names # => [:erc20, :erc721, :erc1155, :erc4626]
      def names = NAMES
    end

    # Builds JSON-ABI definitions from Solidity-like parameter strings ("address to", "uint256 id indexed").
    # @api private
    module Definition
      module_function

      # A `view` function definition.
      #
      # @param name [String] the function name
      # @param inputs [Array<String>] Solidity-like parameters, see {params}
      # @param outputs [Array<String>] Solidity-like return values, see {params}
      # @return [Hash] the JSON-ABI function definition
      def view(name, inputs, outputs) = function(name, inputs, outputs, "view")

      # A `nonpayable` function definition.
      #
      # @param name [String] the function name
      # @param inputs [Array<String>] Solidity-like parameters, see {params}
      # @param outputs [Array<String>] Solidity-like return values, see {params}
      # @return [Hash] the JSON-ABI function definition
      def write(name, inputs, outputs = []) = function(name, inputs, outputs, "nonpayable")

      # A function definition with an explicit state mutability.
      #
      # @param name [String] the function name
      # @param inputs [Array<String>] Solidity-like parameters, see {params}
      # @param outputs [Array<String>] Solidity-like return values, see {params}
      # @param mutability [String] `"view"`, `"pure"`, `"nonpayable"` or `"payable"`
      # @return [Hash] the JSON-ABI function definition
      def function(name, inputs, outputs, mutability)
        { "type" => "function", "name" => name, "stateMutability" => mutability,
          "inputs" => params(inputs), "outputs" => params(outputs) }
      end

      # A non-anonymous event definition.
      #
      # @param name [String] the event name
      # @param inputs [Array<String>] Solidity-like parameters, `indexed` as a third word, see {params}
      # @return [Hash] the JSON-ABI event definition
      def event(name, inputs)
        { "type" => "event", "name" => name, "anonymous" => false, "inputs" => params(inputs) }
      end

      # A custom error definition.
      #
      # @param name [String] the error name
      # @param inputs [Array<String>] Solidity-like parameters, see {params}
      # @return [Hash] the JSON-ABI error definition
      def error(name, inputs)
        { "type" => "error", "name" => name, "inputs" => params(inputs) }
      end

      # JSON-ABI parameters from Solidity-like strings: `"<type> [name] [indexed]"`.
      #
      # @param list [Array<String>] e.g. `["address from indexed", "uint256 value"]`
      # @return [Array<Hash>] the parameters, `"indexed" => true` when the third word is `indexed`
      def params(list)
        list.map do |entry|
          type, name, indexed = entry.split
          param = { "name" => name.to_s, "type" => type }
          param["indexed"] = true if indexed == "indexed"
          param
        end
      end

      # Freezes a definition and everything it contains.
      #
      # @param value [Object] a Hash, an Array or a leaf value
      # @return [Object] the same value, frozen with all its nested Hashes and Arrays
      def deep_freeze(value)
        case value
        when Hash then value.each_value { |v| deep_freeze(v) }
        when Array then value.each { |v| deep_freeze(v) }
        end
        value.freeze
      end
    end
  end
end

require_relative "abis/erc20"
require_relative "abis/erc721"
require_relative "abis/erc1155"
require_relative "abis/erc4626"
