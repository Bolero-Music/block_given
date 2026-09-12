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
    NAMES = %i[erc20 erc721 erc1155 erc4626].freeze

    class << self
      # Shipped ABI by name: `:erc20`, `"ERC721"`, `"erc-1155"` all work.
      def fetch(name)
        key = name.to_s.downcase.delete("-_").to_sym
        raise AbiError, "unknown ABI #{name.inspect} (shipped: #{NAMES.join(', ')})" unless NAMES.include?(key)

        const_get(key.to_s.upcase, false)
      end

      def names = NAMES
    end

    # Builds JSON-ABI definitions from Solidity-like parameter strings ("address to", "uint256 id indexed").
    # @api private
    module Definition
      module_function

      def view(name, inputs, outputs) = function(name, inputs, outputs, "view")
      def write(name, inputs, outputs = []) = function(name, inputs, outputs, "nonpayable")

      def function(name, inputs, outputs, mutability)
        { "type" => "function", "name" => name, "stateMutability" => mutability,
          "inputs" => params(inputs), "outputs" => params(outputs) }
      end

      def event(name, inputs)
        { "type" => "event", "name" => name, "anonymous" => false, "inputs" => params(inputs) }
      end

      def error(name, inputs)
        { "type" => "error", "name" => name, "inputs" => params(inputs) }
      end

      def params(list)
        list.map do |entry|
          type, name, indexed = entry.split
          param = { "name" => name.to_s, "type" => type }
          param["indexed"] = true if indexed == "indexed"
          param
        end
      end

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
