# frozen_string_literal: true

module BlockGiven
  module Abi
    class Function
      attr_reader :name, :inputs, :outputs, :state_mutability

      def initialize(definition)
        definition = definition.transform_keys(&:to_s)
        @name = definition["name"].to_s
        @inputs = Array(definition["inputs"]).each_with_index.map { |i, idx| Parameter.new(i, index: idx) }
        @outputs = Array(definition["outputs"]).each_with_index.map { |o, idx| Parameter.new(o, index: idx) }
        @state_mutability = (definition["stateMutability"] || legacy_mutability(definition)).to_s
      end

      def ruby_name = Utils.snake_case(name).to_sym
      def signature = "#{name}(#{inputs.map(&:type).join(',')})"
      def selector = @selector ||= Utils.keccak256(signature)[0, 10]

      def read? = %w[view pure].include?(state_mutability)
      def write? = !read?
      def payable? = state_mutability == "payable"

      def input_names = inputs.map(&:ruby_name)

      # Positional args or keyword args (matched on snake_cased input names).
      def encode(args = [], kwargs = {})
        values = resolve_args(args, kwargs)
        selector + Utils.strip_hex(Coder.encode(inputs, values))
      end

      # Single output -> value; several -> Array.
      def decode_output(hex)
        values = Coder.decode(outputs, hex)
        outputs.size == 1 ? values.first : values
      end

      def resolve_args(args, kwargs)
        raise InvalidArgumentError, "#{name}: mix of positional and keyword arguments" if !args.empty? && !kwargs.empty?
        return args if kwargs.empty?

        if inputs.any?(&:unnamed?)
          raise InvalidArgumentError, "#{name}: inputs are unnamed in the ABI, use positional arguments"
        end

        normalized = kwargs.transform_keys { |k| Utils.snake_case(k).to_sym }
        unknown = normalized.keys - input_names
        unless unknown.empty?
          raise InvalidArgumentError,
                "#{name}: unknown argument(s) #{unknown.join(', ')} (expected #{input_names.join(', ')})"
        end

        missing = input_names - normalized.keys
        raise InvalidArgumentError, "#{name}: missing argument(s) #{missing.join(', ')}" unless missing.empty?

        input_names.map { |n| normalized[n] }
      end

      def to_s = signature
      def inspect = "#<BlockGiven::Abi::Function #{signature} #{state_mutability}>"

      private

      def legacy_mutability(definition)
        return "payable" if definition["payable"]
        return "view" if definition["constant"]

        "nonpayable"
      end
    end
  end
end
