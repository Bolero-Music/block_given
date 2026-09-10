# frozen_string_literal: true

module Vium
  module Connectors
    # A connector is a JSON-RPC transport. Subclasses implement #request; the
    # chain is passed so multi-network providers (Alchemy) can pick the endpoint.
    class Base
      # @return the JSON-RPC `result` (raw JSON value). Raises Vium::RpcError on error.
      def request(method, params = [], chain: nil)
        raise NotImplementedError, "#{self.class}#request"
      end

      # Naive batch: one request per call. Transports with real batching override it.
      # Returns an array of results; failed calls are returned as RpcError instances.
      def batch(calls, chain: nil)
        calls.map do |(method, params)|
          request(method, params || [], chain: chain)
        rescue RpcError => e
          e
        end
      end

      def name = self.class.name.split("::").last.downcase
    end
  end
end
