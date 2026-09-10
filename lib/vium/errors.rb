# frozen_string_literal: true

module Vium
  # Base class for every error raised by Vium.
  class Error < StandardError; end

  class ConfigurationError < Error; end
  class InvalidArgumentError < Error; end
  class InvalidAddressError < InvalidArgumentError; end
  class WalletRequiredError < Error; end
  class TimeoutError < Error; end

  class AbiError < Error; end
  class FunctionNotFoundError < AbiError; end
  class EventNotFoundError < AbiError; end
  class AmbiguousFunctionError < AbiError; end

  # Transport-level failure (non-2xx HTTP status, connection refused, ...).
  class HttpError < Error
    attr_reader :status, :body

    def initialize(message, status: nil, body: nil)
      super(message)
      @status = status
      @body = body
    end
  end

  # JSON-RPC error object returned by the node.
  class RpcError < Error
    attr_reader :code, :data, :rpc_method

    def initialize(message, code: nil, data: nil, rpc_method: nil)
      super(message)
      @code = code
      @data = data
      @rpc_method = rpc_method
    end

    # Builds the most specific error for a JSON-RPC error payload. Reverts carry
    # ABI-encoded data that we surface as a ContractRevertError.
    def self.from_payload(error, rpc_method: nil)
      error = { "message" => error.to_s } unless error.is_a?(Hash)
      code = error["code"]
      message = error["message"].to_s
      data = error["data"]
      revert_data = extract_revert_data(data)

      if revert_data || message.match?(/revert/i)
        ContractRevertError.new(message, code: code, data: data, rpc_method: rpc_method, revert_data: revert_data)
      else
        new(message, code: code, data: data, rpc_method: rpc_method)
      end
    end

    # Providers disagree on where the revert bytes live: Alchemy/geth put them in
    # `data`, Hardhat/Anvil nest them under `data.data`.
    def self.extract_revert_data(data)
      case data
      when String then data.start_with?("0x") ? data : nil
      when Hash then extract_revert_data(data["data"] || data[:data])
      end
    end
  end

  # eth_call / eth_estimateGas / eth_sendRawTransaction rejected by the EVM.
  class ContractRevertError < RpcError
    ERROR_STRING_SELECTOR = "0x08c379a0"
    PANIC_SELECTOR = "0x4e487b71"
    PANIC_REASONS = {
      0x00 => "generic compiler inserted panic",
      0x01 => "assertion failed",
      0x11 => "arithmetic overflow or underflow",
      0x12 => "division or modulo by zero",
      0x21 => "invalid enum conversion",
      0x22 => "incorrectly encoded storage byte array",
      0x31 => "pop() on an empty array",
      0x32 => "array index out of bounds",
      0x41 => "too much memory allocated or array too large",
      0x51 => "call to a zero-initialized variable of internal function type"
    }.freeze

    attr_reader :revert_data, :error_name, :args

    def initialize(message, code: nil, data: nil, rpc_method: nil, revert_data: nil, error_name: nil, args: nil)
      @revert_data = revert_data
      @error_name = error_name
      @args = args
      super(build_message(message), code: code, data: data, rpc_method: rpc_method)
    end

    # Human readable revert reason when it can be decoded (Error(string) / Panic).
    def reason
      return @reason if defined?(@reason)

      @reason = decode_builtin_reason
    end

    def selector
      revert_data && revert_data.length >= 10 ? revert_data[0, 10] : nil
    end

    def custom_error?
      !selector.nil? && ![ERROR_STRING_SELECTOR, PANIC_SELECTOR].include?(selector)
    end

    # Returns a copy of this error enriched with a custom error decoded from the
    # given ABI interface, or self when the interface does not know the selector.
    def decode_with(interface)
      return self unless custom_error? && interface

      custom = interface.error_by_selector(selector)
      return self unless custom

      decoded = custom.decode(revert_data)
      self.class.new(
        "#{custom.name}(#{decoded.values.map(&:inspect).join(', ')})",
        code: code, data: data, rpc_method: rpc_method, revert_data: revert_data,
        error_name: custom.name, args: decoded
      )
    end

    private

    def build_message(original)
      reason = decode_builtin_reason
      return "execution reverted: #{reason}" if reason && !original.include?(reason)

      original.empty? ? "execution reverted" : original
    end

    def decode_builtin_reason
      return nil unless revert_data && revert_data.length > 10

      payload = "0x#{revert_data[10..]}"
      case selector
      when ERROR_STRING_SELECTOR
        Eth::Abi.decode(["string"], payload).first
      when PANIC_SELECTOR
        panic_code = Eth::Abi.decode(["uint256"], payload).first
        "Panic(0x#{panic_code.to_s(16).rjust(2, '0')}): #{PANIC_REASONS.fetch(panic_code, 'unknown panic')}"
      end
    rescue StandardError
      nil
    end
  end

  # Raised by Transaction#wait! when the mined receipt has a failed status.
  class TransactionRevertedError < Error
    attr_reader :receipt

    def initialize(receipt)
      @receipt = receipt
      super("transaction #{receipt.transaction_hash} reverted in block #{receipt.block_number}")
    end
  end
end
