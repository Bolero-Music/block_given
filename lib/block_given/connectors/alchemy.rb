# frozen_string_literal: true

module BlockGiven
  module Connectors
    # Alchemy JSON-RPC connector. The endpoint is derived from the chain, so one
    # connector instance can serve any Alchemy-supported network.
    #
    #   BlockGiven::Connectors::Alchemy.new(api_key: ENV["ALCHEMY_API_KEY"])
    class Alchemy < Http
      attr_reader :api_key

      def initialize(api_key:, timeout: 30, retries: 3, retry_delay: 0.5, logger: nil, headers: {})
        raise ConfigurationError, "Alchemy api_key is required" if api_key.nil? || api_key.to_s.empty?

        @api_key = api_key.to_s
        super(url: nil, headers: headers, timeout: timeout, retries: retries, retry_delay: retry_delay, logger: logger)
      end

      def endpoint(chain)
        raise ConfigurationError, "Alchemy connector needs a chain" if chain.nil?
        raise ConfigurationError, "#{chain.name} is not available on Alchemy" unless chain.alchemy_network

        "https://#{chain.alchemy_network}.g.alchemy.com/v2/#{api_key}"
      end

      def inspect = "#<BlockGiven::Connectors::Alchemy api_key=#{redacted_key}>"

      # Keeps the network host visible, masks the key: https://base-mainnet.g.alchemy.com/v2/abcd…
      def redact(endpoint) = endpoint.to_s.sub(api_key, redacted_key)

      private

      def redacted_key = "#{api_key[0, 4]}…"
    end
  end
end
