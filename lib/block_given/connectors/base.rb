# frozen_string_literal: true

module BlockGiven
  # JSON-RPC transports: {Connectors::Base} defines the interface, {Connectors::Http} speaks JSON-RPC over HTTP(S),
  # {Connectors::Alchemy} derives Alchemy endpoints from the chain and {Connectors::Stub} serves canned responses
  # in tests. A connector is set globally with `BlockGiven.config.connector` or passed to {Client#initialize}.
  module Connectors
    # Abstract JSON-RPC transport every connector derives from.
    #
    # A connector only knows how to send a JSON-RPC method with its params and hand back the `result`.
    # The {Chain} is passed on each call so that multi-network providers ({Alchemy}) can derive the endpoint
    # from it; single-endpoint transports ({Http} with an explicit `url:`) may ignore it. Concrete
    # connectors: {Http}, {Alchemy} and, for tests, {Stub}.
    #
    # @abstract Subclass and override {#request}; override {#batch} when the transport supports real batching.
    class Base
      # Sends one JSON-RPC request and returns its `result`.
      #
      # @abstract
      # @param method [String] JSON-RPC method name, e.g. `"eth_blockNumber"`
      # @param params [Array<Object>] positional JSON-RPC params
      # @param chain [Chain, nil] chain being queried, used by multi-network transports to pick an endpoint
      # @return [Object] the raw JSON-RPC `result` (String, Hash, Array, nil...), undecoded
      # @raise [RpcError] when the node answers with a JSON-RPC error object
      # @raise [NotImplementedError] when called on {Base} itself
      def request(method, params = [], chain: nil)
        raise NotImplementedError, "#{self.class}#request"
      end

      # Executes several calls and returns their results in order.
      #
      # This naive implementation issues one {#request} per call; transports with real JSON-RPC batching
      # override it. A call that fails with an {RpcError} does not abort the batch: the error instance takes
      # the place of its result.
      #
      # @param calls [Array<Array(String, Array)>] `[method, params]` pairs; a missing params entry means `[]`
      # @param chain [Chain, nil] chain being queried, forwarded to {#request}
      # @return [Array<Object, RpcError>] one raw result (or {RpcError}) per call, in the same order
      def batch(calls, chain: nil)
        calls.map do |(method, params)|
          request(method, params || [], chain: chain)
        rescue RpcError => e
          e
        end
      end

      # Short lowercase name of the transport, derived from the class name.
      #
      # @return [String] e.g. `"http"`, `"alchemy"` or `"stub"`
      def name = self.class.name.split("::").last.downcase
    end
  end
end
