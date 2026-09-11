# frozen_string_literal: true

module UncleBlockGiven
  module Connectors
    # In-memory connector for tests. Responses can be static values, sequences
    # (consumed in order, last value repeats) or procs receiving the params.
    #
    #   stub = UncleBlockGiven::Connectors::Stub.new(
    #     "eth_blockNumber" => UncleBlockGiven::Connectors::Stub.sequence("0x10", "0x11"),
    #     "eth_call" => ->(params) { "0x" + "0" * 63 + "1" }
    #   )
    #   stub.calls # => [["eth_blockNumber", []], ...]
    class Stub < Base
      class Sequence
        def initialize(values)
          @values = values.dup
        end

        def next
          @values.size > 1 ? @values.shift : @values.first
        end
      end

      def self.sequence(*values) = Sequence.new(values)

      attr_reader :calls

      def initialize(responses = {}, &handler)
        super()
        @responses = {}
        @handler = handler
        @calls = []
        responses.each { |method, value| stub(method, value) }
      end

      def stub(method, value = nil, &block)
        @responses[method.to_s] = block || value
        self
      end

      def request(method, params = [], chain: nil)
        @calls << [method.to_s, params]
        value = resolve(method.to_s, params, chain)
        raise value if value.is_a?(Exception)

        value
      end

      def calls_for(method) = calls.select { |(m, _)| m == method.to_s }.map(&:last)
      def reset! = @calls.clear

      private

      def resolve(method, params, chain)
        if @responses.key?(method)
          value = @responses[method]
          value = value.next if value.is_a?(Sequence)
          return value.is_a?(Proc) ? value.call(params) : value
        end
        return @handler.call(method, params, chain) if @handler

        raise RpcError.new("no stub for #{method}", code: -32_601, rpc_method: method)
      end
    end
  end
end
