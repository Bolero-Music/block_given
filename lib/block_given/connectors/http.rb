# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module BlockGiven
  module Connectors
    # Generic JSON-RPC over HTTP(S) transport with retries and exponential backoff.
    #
    #   BlockGiven::Connectors::Http.new(url: "http://127.0.0.1:8545")
    #   BlockGiven::Connectors::Http.new # -> falls back to chain.rpc_urls.first
    class Http < Base
      RETRIABLE_STATUSES = [408, 425, 429, 500, 502, 503, 504].freeze
      RETRIABLE_RPC_CODES = [-32_005, -32_603, 429].freeze # rate limited / internal error
      RETRIABLE_EXCEPTIONS = [Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED,
                              Errno::EHOSTUNREACH, EOFError, SocketError, OpenSSL::SSL::SSLError].freeze

      attr_reader :url, :headers, :timeout, :retries, :retry_delay

      def initialize(url: nil, headers: {}, timeout: 30, retries: 3, retry_delay: 0.5, logger: nil)
        super()
        @url = url
        user_agent = "block_given/#{BlockGiven::VERSION}"
        @headers = { "Content-Type" => "application/json", "User-Agent" => user_agent }.merge(headers)
        @timeout = timeout
        @retries = retries
        @retry_delay = retry_delay
        @logger = logger
        @id = 0
        @mutex = Mutex.new
      end

      def endpoint(chain)
        return url if url

        chain&.rpc_urls&.first ||
          raise(ConfigurationError, "no RPC url: pass url: to the connector or use a chain with rpc_urls")
      end

      def request(method, params = [], chain: nil)
        payload = { jsonrpc: "2.0", id: next_id, method: method, params: params }
        body = with_retries(method) { post(endpoint(chain), payload) }
        handle_single(body, method)
      end

      def batch(calls, chain: nil)
        return [] if calls.empty?

        payload = calls.map { |(method, params)| { jsonrpc: "2.0", id: next_id, method: method, params: params || [] } }
        body = with_retries("batch") { post(endpoint(chain), payload) }
        raise RpcError, "batch response is not an array: #{body.inspect}" unless body.is_a?(Array)

        by_id = body.to_h { |entry| [entry["id"], entry] }
        payload.map do |req|
          entry = by_id[req[:id]] || { "error" => { "message" => "missing response for id #{req[:id]}" } }
          if entry.key?("error")
            RpcError.from_payload(entry["error"], rpc_method: req[:method])
          else
            entry["result"]
          end
        end
      end

      def inspect = "#<#{self.class.name} url=#{url ? redact(url).inspect : 'chain default'}>"

      # Endpoint as it may appear in logs and error messages. RPC URLs usually carry
      # the API key in their path (Infura, QuickNode, ...), so only scheme and host are kept.
      def redact(endpoint)
        uri = URI.parse(endpoint.to_s)
        host = uri.port && uri.port != uri.default_port ? "#{uri.host}:#{uri.port}" : uri.host
        path = uri.path.to_s.delete_prefix("/").empty? ? "" : "/…"
        "#{uri.scheme}://#{host}#{path}"
      rescue URI::InvalidURIError
        "<invalid url>"
      end

      private

      def logger = @logger || BlockGiven.config.logger

      def next_id
        @mutex.synchronize { @id += 1 }
      end

      def handle_single(body, method)
        raise RpcError.new("unexpected JSON-RPC response: #{body.inspect}", rpc_method: method) unless body.is_a?(Hash)

        if body.key?("error")
          error = RpcError.from_payload(body["error"], rpc_method: method)
          raise error unless RETRIABLE_RPC_CODES.include?(error.code) && !error.is_a?(ContractRevertError)

          raise Retry, error
        end
        body["result"]
      end

      # Internal signal used to retry on retriable JSON-RPC errors.
      class Retry < StandardError
        attr_reader :cause_error

        def initialize(cause_error)
          @cause_error = cause_error
          super(cause_error.message)
        end
      end

      def with_retries(method)
        attempt = 0
        loop do
          begin
            return yield
          rescue Retry => e
            raise e.cause_error if attempt >= retries
          rescue HttpError => e
            raise unless RETRIABLE_STATUSES.include?(e.status) && attempt < retries
          rescue *RETRIABLE_EXCEPTIONS => e
            raise HttpError, "#{e.class}: #{e.message}" unless attempt < retries
          end
          attempt += 1
          delay = retry_delay * (2**(attempt - 1))
          logger.debug { "[block_given] retrying #{method} (attempt #{attempt}/#{retries}) in #{delay}s" }
          sleep(delay)
        end
      end

      def post(endpoint, payload)
        uri = URI.parse(endpoint)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = timeout
        http.read_timeout = timeout
        http.write_timeout = timeout if http.respond_to?(:write_timeout=)

        request = Net::HTTP::Post.new(uri.request_uri, headers)
        request.body = JSON.generate(payload)
        response = http.request(request)

        unless response.is_a?(Net::HTTPSuccess)
          raise HttpError.new("HTTP #{response.code} from #{redact(endpoint)}: #{response.body.to_s[0, 200]}",
                              status: response.code.to_i, body: response.body)
        end

        JSON.parse(response.body)
      rescue JSON::ParserError => e
        raise HttpError.new("invalid JSON from RPC endpoint: #{e.message}", body: response&.body)
      end
    end
  end
end
