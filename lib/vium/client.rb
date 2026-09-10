# frozen_string_literal: true

module Vium
  # Public JSON-RPC client bound to a chain and a connector (viem's PublicClient).
  #
  #   client = Vium::Client.new(chain: :base, connector: Vium::Connectors::Alchemy.new(api_key: "..."))
  #   client.block_number
  #   client.get_balance("0x...")
  class Client
    attr_reader :chain, :connector

    def initialize(chain: nil, connector: nil, polling_interval: nil, timeout: nil, logger: nil)
      @chain = chain ? Chains.resolve(chain) : Vium.config.chain!
      @connector = connector || Vium.config.connector!
      @polling_interval = polling_interval
      @timeout = timeout
      @logger = logger
    end

    def polling_interval = @polling_interval || Vium.config.polling_interval
    def timeout = @timeout || Vium.config.timeout
    def logger = @logger || Vium.config.logger

    # Raw JSON-RPC call: client.request("eth_blockNumber") / client.request("eth_getBalance", addr, "latest")
    def request(method, *params)
      logger.debug { "[vium] -> #{method} #{params.inspect}" }
      result = connector.request(method, params, chain: chain)
      logger.debug { "[vium] <- #{method} #{result.inspect[0, 200]}" }
      result
    end

    # Batched JSON-RPC: client.batch([["eth_blockNumber"], ["eth_chainId"]])
    def batch(calls) = connector.batch(calls, chain: chain)

    # --- Chain / blocks -----------------------------------------------------

    def chain_id = Utils.hex_to_int(request("eth_chainId"))
    def block_number = Utils.hex_to_int(request("eth_blockNumber"))

    def get_block(block = :latest, include_transactions: false)
      method = Utils.hex?(block.to_s) && block.to_s.length == 66 ? "eth_getBlockByHash" : "eth_getBlockByNumber"
      raw = request(method, block_param(block), include_transactions)
      raw && Normalizer.normalize(raw)
    end

    def gas_price = Utils.hex_to_int(request("eth_gasPrice"))

    def max_priority_fee_per_gas
      Utils.hex_to_int(request("eth_maxPriorityFeePerGas"))
    rescue RpcError
      Utils.parse_gwei("1") # method not supported by every node
    end

    # EIP-1559 fee estimation (viem semantics: baseFee * multiplier + priority fee).
    def estimate_fees_per_gas(base_fee_multiplier: nil)
      multiplier = base_fee_multiplier || Vium.config.base_fee_multiplier
      block = get_block(:latest)
      base_fee = block[:base_fee_per_gas] || gas_price
      priority = max_priority_fee_per_gas
      {
        base_fee_per_gas: base_fee,
        max_priority_fee_per_gas: priority,
        max_fee_per_gas: (base_fee * multiplier).ceil + priority
      }
    end

    # --- Accounts -----------------------------------------------------------

    def get_balance(address, block: :latest)
      Utils.hex_to_int(request("eth_getBalance", Utils.checksum_address(address), Utils.block_tag(block)))
    end

    def get_transaction_count(address, block: :pending)
      Utils.hex_to_int(request("eth_getTransactionCount", Utils.checksum_address(address), Utils.block_tag(block)))
    end

    def get_code(address, block: :latest)
      request("eth_getCode", Utils.checksum_address(address), Utils.block_tag(block))
    end

    def contract?(address) = get_code(address) != "0x"

    def get_storage_at(address, slot, block: :latest)
      request("eth_getStorageAt", Utils.checksum_address(address), Utils.to_hex(slot), Utils.block_tag(block))
    end

    # --- Calls --------------------------------------------------------------

    # Executes a read-only call. Returns the raw hex result.
    def call(to:, data:, from: nil, value: nil, gas: nil, block: :latest)
      request("eth_call", call_object(to: to, data: data, from: from, value: value, gas: gas), Utils.block_tag(block))
    end

    def estimate_gas(to:, data: nil, from: nil, value: nil)
      Utils.hex_to_int(request("eth_estimateGas", call_object(to: to, data: data, from: from, value: value)))
    end

    # --- Transactions -------------------------------------------------------

    def send_raw_transaction(raw)
      Transaction.new(request("eth_sendRawTransaction", Utils.prefix_hex(raw)), client: self)
    end

    def transaction(hash) = Transaction.new(hash, client: self)

    def get_transaction(hash)
      raw = request("eth_getTransactionByHash", hash)
      raw && Normalizer.normalize(raw)
    end

    def get_transaction_receipt(hash)
      raw = request("eth_getTransactionReceipt", hash)
      raw && Receipt.new(raw)
    end

    # Polls until the receipt is available (and confirmed by N blocks).
    def wait_for_transaction_receipt(hash, confirmations: nil, timeout: nil, polling_interval: nil)
      confirmations ||= Vium.config.confirmations
      interval = polling_interval || self.polling_interval
      Poller.poll(interval: interval, timeout: timeout || self.timeout, description: "receipt of #{hash}") do
        receipt = get_transaction_receipt(hash)
        next nil unless receipt&.block_number
        next receipt if confirmations <= 1

        block_number - receipt.block_number + 1 >= confirmations ? receipt : nil
      end
    end

    # --- Logs ---------------------------------------------------------------

    def get_logs(address: nil, topics: nil, from_block: :latest, to_block: :latest, block_hash: nil)
      filter = {}
      filter[:address] = Array(address).map { |a| Utils.checksum_address(a) } if address
      filter[:address] = filter[:address].first if filter[:address]&.size == 1
      filter[:topics] = topics if topics
      if block_hash
        filter[:blockHash] = block_hash
      else
        filter[:fromBlock] = Utils.block_tag(from_block)
        filter[:toBlock] = Utils.block_tag(to_block)
      end
      Normalizer.normalize(request("eth_getLogs", filter))
    end

    # --- Watchers (background polling) --------------------------------------

    # Yields each new block number. With emit_missed: true every block between two
    # polls is yielded, otherwise only the latest one.
    def watch_block_number(polling_interval: nil, emit_missed: false, &block)
      last = nil
      watcher("block_number", polling_interval) do
        current = block_number
        next if last && current <= last

        if emit_missed && last
          ((last + 1)..current).each { |n| block.call(n) }
        else
          block.call(current)
        end
        last = current
      end
    end

    def watch_blocks(polling_interval: nil, include_transactions: false, &block)
      watch_block_number(polling_interval: polling_interval, emit_missed: true) do |number|
        block.call(get_block(number, include_transactions: include_transactions))
      end
    end

    # get_logs over a large range, split in chunks of max_block_range blocks so provider
    # limits are respected. Yields each chunk's logs when a block is given, else returns them all.
    def get_logs_in_chunks(from_block:, address: nil, topics: nil, to_block: :latest, max_block_range: nil)
      size = max_block_range || Vium.config.max_block_range
      to_block = block_number if to_block.nil? || Utils::BLOCK_TAGS.include?(to_block.to_s)
      collected = []
      from = from_block
      while from <= to_block
        to = [from + size - 1, to_block].min
        logs = get_logs(address: address, topics: topics, from_block: from, to_block: to)
        block_given? ? yield(logs, from, to) : collected.concat(logs)
        from = to + 1
      end
      collected
    end

    # Yields new logs matching the filter, one Array per processed block range.
    #
    #   from_block:      resume from this block (catch-up is chunked by max_block_range)
    #   confirmations:   stay this many blocks behind the head to dodge reorgs (default 0)
    #   on_progress:     ->(from, to) called after each range is processed: persist `to` as your cursor
    #   watcher.cursor:  last processed block number
    def watch_logs(address: nil, topics: nil, from_block: nil, polling_interval: nil, max_block_range: nil,
                   confirmations: 0, on_progress: nil, &block)
      last = from_block ? from_block - 1 : block_number - confirmations
      watcher("logs", polling_interval) do |watcher|
        watcher.cursor ||= last
        head = block_number - confirmations
        while last < head && !watcher.stopped?
          to = [last + (max_block_range || Vium.config.max_block_range), head].min
          logs = get_logs(address: address, topics: topics, from_block: last + 1, to_block: to)
          block.call(logs) unless logs.empty?
          on_progress&.call(last + 1, to)
          last = watcher.cursor = to
        end
      end
    end

    # Generic background watcher on this client.
    def watcher(name, polling_interval = nil, &)
      Watcher.new(interval: polling_interval || self.polling_interval, name: name, logger: logger, &).start
    end

    def inspect = "#<Vium::Client chain=#{chain} connector=#{connector.inspect}>"

    private

    def block_param(block)
      return block if Utils.hex?(block.to_s) && block.to_s.length == 66

      Utils.block_tag(block)
    end

    def call_object(to:, data:, from:, value:, gas: nil)
      obj = { to: Utils.checksum_address(to) }
      obj[:data] = Utils.prefix_hex(data) if data && data != ""
      obj[:from] = Utils.checksum_address(from) if from
      obj[:value] = Utils.to_hex(value) if value && value != 0
      obj[:gas] = Utils.to_hex(gas) if gas
      obj
    end
  end
end
