# frozen_string_literal: true

module BlockGiven
  module Connectors
    # In-memory connector for tests: no network, canned responses, and a record of every call.
    #
    # Responses are registered per JSON-RPC method name and can be:
    # - a static value, returned on every call;
    # - a {Sequence} built with {Stub.sequence}, consumed in order, the last value repeating forever;
    # - a Proc receiving the request params, for param-dependent answers;
    # - an Exception instance, raised instead of returned (e.g. an {RpcError} to simulate a node error).
    # A handler block given to {Stub#initialize} answers every method without a registered response. Methods with
    # neither raise an {RpcError} with code -32601 ("method not found").
    #
    # @example Static values, a sequence and a proc
    #   stub = BlockGiven::Connectors::Stub.new(
    #     "eth_chainId" => "0x2105",
    #     "eth_blockNumber" => BlockGiven::Connectors::Stub.sequence("0x10", "0x11"),
    #     "eth_call" => ->(params) { params.first[:to] == usdc ? "0x" + "0" * 63 + "1" : "0x" }
    #   )
    #   client = BlockGiven::Client.new(chain: :base, connector: stub)
    #   client.block_number       # => 16
    #   client.block_number       # => 17 (and 17 again afterwards)
    #   stub.calls                # => [["eth_blockNumber", []], ["eth_blockNumber", []]]
    #   stub.calls_for("eth_call") # => params of each eth_call
    # @example Fallback handler and incremental stubbing
    #   stub = BlockGiven::Connectors::Stub.new { |method, params, chain| raise "unexpected #{method}" }
    #   stub.stub("eth_gasPrice", "0x3b9aca00").stub("eth_estimateGas") { |params| "0x5208" }
    class Stub < Base
      # Ordered list of canned responses: each call consumes the next value, the last one repeats forever.
      # Build one with {Stub.sequence}.
      class Sequence
        # @param values [Array<Object>] responses in the order they should be served (copied, not mutated)
        def initialize(values)
          @values = values.dup
        end

        # Consumes and returns the next value; once a single value is left it is returned on every call.
        #
        # @return [Object, nil] the next response (nil for an empty sequence)
        def next
          @values.size > 1 ? @values.shift : @values.first
        end
      end

      # Builds a {Sequence} of responses for a stubbed method.
      #
      # @example
      #   stub.stub("eth_blockNumber", BlockGiven::Connectors::Stub.sequence("0x10", "0x11", "0x12"))
      # @param values [Array<Object>] responses served in order; the last one repeats once reached
      # @return [Sequence]
      def self.sequence(*values) = Sequence.new(values)

      # @!attribute [r] calls
      #   @return [Array<Array(String, Array)>] every request received so far as `[method, params]` pairs, in
      #     order, including those that raised; cleared by {#reset!}

      attr_reader :calls

      # Builds a stub connector with an initial set of canned responses and an optional fallback handler.
      #
      # @param responses [Hash{String, Symbol => Object}] method name to response (static value, {Sequence},
      #   Proc receiving the params, or Exception to raise); each entry goes through {#stub}
      # @yield [method, params, chain] for every request whose method has no registered response
      # @yieldparam method [String] JSON-RPC method name
      # @yieldparam params [Array<Object>] request params
      # @yieldparam chain [Chain, nil] chain passed by the client
      # @yieldreturn [Object] the value to use as the JSON-RPC `result` (raised when it is an Exception)
      def initialize(responses = {}, &handler)
        super()
        @responses = {}
        @handler = handler
        @calls = []
        responses.each { |method, value| stub(method, value) }
      end

      # Registers (or replaces) the response of one JSON-RPC method.
      #
      # @param method [String, Symbol] JSON-RPC method name
      # @param value [Object, Sequence, Proc, Exception, nil] static value, {Sequence}, Proc receiving the params,
      #   or Exception instance to raise; ignored when a block is given
      # @yield [params] when a block is given it computes the response on every call
      # @yieldparam params [Array<Object>] request params
      # @yieldreturn [Object] the value to use as the JSON-RPC `result` (raised when it is an Exception)
      # @return [self] for chaining
      def stub(method, value = nil, &block)
        @responses[method.to_s] = block || value
        self
      end

      # Records the call and returns the canned response for `method`.
      #
      # @param method [String, Symbol] JSON-RPC method name
      # @param params [Array<Object>] request params, recorded and passed to Proc responses / the handler
      # @param chain [Chain, nil] chain passed by the client, forwarded to the handler block only
      # @return [Object] the resolved response (a {Sequence} is advanced, a Proc is called with `params`)
      # @raise [Exception] the resolved response itself when it is an Exception instance
      # @raise [RpcError] with code -32601 when the method has no response and no handler was given
      def request(method, params = [], chain: nil)
        @calls << [method.to_s, params]
        value = resolve(method.to_s, params, chain)
        raise value if value.is_a?(Exception)

        value
      end

      # Params of every recorded call to one method, in order.
      #
      # @param method [String, Symbol] JSON-RPC method name
      # @return [Array<Array<Object>>] one params Array per call (empty when the method was never called)
      def calls_for(method) = calls.select { |(m, _)| m == method.to_s }.map(&:last)

      # Forgets every recorded call; registered responses (and sequence positions) are kept.
      #
      # @return [Array] the emptied {#calls} Array
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
