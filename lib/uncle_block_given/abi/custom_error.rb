# frozen_string_literal: true

module UncleBlockGiven
  module Abi
    # Solidity custom error (`error InsufficientBalance(uint256 available, uint256 required)`).
    class CustomError
      attr_reader :name, :inputs

      def initialize(definition)
        definition = definition.transform_keys(&:to_s)
        @name = definition["name"].to_s
        @inputs = Array(definition["inputs"]).each_with_index.map { |i, idx| Parameter.new(i, index: idx) }
      end

      def signature = "#{name}(#{inputs.map(&:type).join(',')})"
      def selector = @selector ||= Utils.keccak256(signature)[0, 10]

      # Returns a Hash of decoded arguments keyed by snake_case names.
      def decode(revert_data)
        payload = "0x#{Utils.strip_hex(revert_data)[8..]}"
        return {} if inputs.empty?

        inputs.map(&:ruby_name).zip(Coder.decode(inputs, payload)).to_h
      end

      def inspect = "#<UncleBlockGiven::Abi::CustomError #{signature}>"
    end
  end
end
