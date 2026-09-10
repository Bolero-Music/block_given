# frozen_string_literal: true

module Vium
  module Abi
    class Event
      attr_reader :name, :inputs, :anonymous

      def initialize(definition)
        definition = definition.transform_keys(&:to_s)
        @name = definition["name"].to_s
        @inputs = Array(definition["inputs"]).each_with_index.map { |i, idx| Parameter.new(i, index: idx) }
        @anonymous = !!definition["anonymous"]
      end

      def ruby_name = Utils.snake_case(name).to_sym
      def signature = "#{name}(#{inputs.map(&:type).join(',')})"
      def topic = @topic ||= Utils.keccak256(signature)
      def anonymous? = anonymous

      def indexed_inputs = inputs.select(&:indexed?)
      def data_inputs = inputs.reject(&:indexed?)

      def matches?(log)
        topic0 = Array(log[:topics] || log["topics"]).first
        !anonymous? && topic0&.downcase == topic
      end

      # Decodes a normalized log (Hash with :topics and :data) into a Vium::Event.
      def decode(log)
        topics = Array(log[:topics] || log["topics"])
        data = log[:data] || log["data"] || "0x"
        indexed_topics = anonymous? ? topics : topics[1..] || []

        args = {}
        indexed_inputs.each_with_index do |param, i|
          args[param.ruby_name] = decode_topic(indexed_topics[i], param)
        end
        unless data_inputs.empty?
          Coder.decode(data_inputs, data).each_with_index do |value, i|
            args[data_inputs[i].ruby_name] = value
          end
        end
        # keep declaration order
        ordered = inputs.to_h { |p| [p.ruby_name, args[p.ruby_name]] }
        Vium::Event.new(name: name, signature: signature, args: ordered, log: log)
      end

      # Builds the topics filter array for eth_getLogs from indexed argument values.
      # Values can be nil (wildcard), a single value or an Array (OR).
      def encode_topics(filters = {})
        normalized = filters.transform_keys { |k| Utils.snake_case(k).to_sym }
        unknown = normalized.keys - indexed_inputs.map(&:ruby_name)
        unless unknown.empty?
          indexed = indexed_inputs.map(&:ruby_name).join(", ")
          raise InvalidArgumentError, "#{name}: #{unknown.join(', ')} is not an indexed parameter (indexed: #{indexed})"
        end

        topics = indexed_inputs.map do |param|
          value = normalized[param.ruby_name]
          next nil if value.nil?

          value.is_a?(Array) ? value.map { |v| encode_topic(v, param) } : encode_topic(value, param)
        end
        topics = topics.reverse.drop_while(&:nil?).reverse # trailing wildcards are implicit
        anonymous? ? topics : [topic, *topics]
      end

      def to_s = signature
      def inspect = "#<Vium::Abi::Event #{signature}>"

      private

      def decode_topic(topic, param)
        return nil if topic.nil?
        return topic if param.dynamic? # only the keccak hash of the value is available

        Coder.decode([param], topic).first
      end

      def encode_topic(value, param)
        return Utils.keccak256(param.raw_type == "string" ? value.to_s : value) if param.dynamic?

        Utils.prefix_hex(Utils.strip_hex(Coder.encode([param], [value])))
      end
    end
  end
end
