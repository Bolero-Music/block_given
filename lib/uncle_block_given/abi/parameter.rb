# frozen_string_literal: true

module UncleBlockGiven
  module Abi
    # One ABI input/output. Knows its canonical Solidity type ("(uint256,address)[]").
    class Parameter
      attr_reader :name, :raw_type, :components, :indexed, :internal_type

      def initialize(definition, index: 0)
        definition = definition.transform_keys(&:to_s)
        @name = definition["name"].to_s
        @name = "arg#{index}" if @name.empty?
        @unnamed = definition["name"].to_s.empty?
        @raw_type = definition["type"].to_s
        @indexed = definition["indexed"] ? true : false
        @internal_type = definition["internalType"]
        @components = Array(definition["components"]).each_with_index.map { |c, i| Parameter.new(c, index: i) }
      end

      def unnamed? = @unnamed
      def indexed? = indexed
      def ruby_name = Utils.snake_case(name).to_sym

      def tuple? = raw_type.start_with?("tuple")
      def array? = raw_type.end_with?("]")

      # "tuple[]" with components -> "(uint256,address)[]"
      def type
        return raw_type unless tuple?

        raw_type.sub("tuple", "(#{components.map(&:type).join(',')})")
      end

      # Base type without the outermost array dimension.
      def element
        return nil unless array?

        Parameter.new(
          { "name" => name, "type" => raw_type.sub(/\[\d*\]\z/, ""),
            "components" => components.map(&:to_h) }
        )
      end

      def dynamic?
        raw_type == "string" || raw_type == "bytes" || raw_type.end_with?("[]") ||
          (tuple? && components.any?(&:dynamic?)) || (array? && element.dynamic?)
      end

      def to_h
        h = { "name" => unnamed? ? "" : name, "type" => raw_type }
        h["components"] = components.map(&:to_h) if tuple?
        h["indexed"] = indexed if indexed
        h
      end
    end
  end
end
