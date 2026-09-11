# frozen_string_literal: true

RSpec.describe UncleBlockGiven::Contract do
  let(:stub) { build_stub }
  let(:wallet) { UncleBlockGiven::Wallet.new(private_key: TEST_PRIVATE_KEY) }
  let(:usdc) { TestERC20.new(address: USDC_BASE, wallet: wallet) }
  let(:transfer_topic) { "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" }

  before { configure_uncle_block_given(stub) }

  describe "class-level DSL" do
    it "declares abi, default address and chain, inherited by subclasses" do
      klass = Class.new(described_class) do
        abi [{ "type" => "function", "name" => "owner", "stateMutability" => "view", "inputs" => [],
               "outputs" => [{ "name" => "", "type" => "address" }] }]
        address USDC_BASE.downcase
        chain :base
      end
      sub = Class.new(klass)
      expect(klass.address).to eq(USDC_BASE)
      expect(klass.new.address).to eq(USDC_BASE)
      expect(sub.new).to respond_to(:owner)
      expect(sub.chain).to eq(UncleBlockGiven::Chains::BASE)
    end

    it "resolves abi_file against UncleBlockGiven.config.abi_path" do
      UncleBlockGiven.configure { |c| c.abi_path = FIXTURES }
      klass = Class.new(described_class) { abi_file "erc20.json" }
      expect(klass.functions.map(&:name)).to include("transfer")
      expect { Class.new(described_class) { abi_file "missing.json" } }.to raise_error(UncleBlockGiven::AbiError, /not found/)
    end

    it "requires an ABI and an address" do
      expect { Class.new(described_class).new(address: USDC_BASE) }.to raise_error(UncleBlockGiven::AbiError)
      expect { TestERC20.new }.to raise_error(UncleBlockGiven::InvalidArgumentError, /address is required/)
    end

    it "does not override reserved methods" do
      klass = Class.new(described_class) do
        abi [{ "type" => "function", "name" => "address", "stateMutability" => "view", "inputs" => [],
               "outputs" => [{ "name" => "", "type" => "address" }] },
             { "type" => "function", "name" => "send", "stateMutability" => "nonpayable", "inputs" => [], "outputs" => [] }]
      end
      instance = klass.new(address: USDC_BASE)
      expect(instance.address).to eq(USDC_BASE)
      expect(instance.method(:send).owner).to eq(Kernel)
    end
  end

  describe "reads" do
    it "calls view functions and decodes the result" do
      stub.stub("eth_call", word(1_000_000))
      expect(usdc.balance_of(OTHER_ADDRESS)).to eq(1_000_000)
      expect(stub.calls_for("eth_call").last)
        .to eq([{ to: USDC_BASE, data: "0x70a08231#{UncleBlockGiven::Utils.strip_hex(word(OTHER_ADDRESS)).downcase}",
                  from: TEST_ADDRESS }, "latest"])
    end

    it "supports keyword arguments and the tx: block override" do
      stub.stub("eth_call", word(5))
      expect(usdc.balance_of(account: OTHER_ADDRESS, tx: { block: 100 })).to eq(5)
      expect(stub.calls_for("eth_call").last.last).to eq("0x64")
    end

    it "decodes strings" do
      stub.stub("eth_call", abi_encode(["string"], ["USD Coin"]))
      expect(usdc.name).to eq("USD Coin")
    end

    it "works without a wallet" do
      stub.stub("eth_call", word(6))
      token = TestERC20.at(USDC_BASE)
      expect(token.decimals).to eq(6)
      expect(token.parse_amount("1.5")).to eq(1_500_000)
      expect(token.format_amount(1_500_000)).to eq("1.5")
      expect(stub.calls_for("eth_call").last.first).not_to have_key(:from)
    end

    it "decodes revert reasons with the contract ABI" do
      error = usdc.interface.error_by_selector(UncleBlockGiven::Utils.keccak256("ERC20InsufficientBalance(address,uint256,uint256)")[0, 10])
      data = error.selector + UncleBlockGiven::Utils.strip_hex(abi_encode(%w[address uint256 uint256], [TEST_ADDRESS, 5, 10]))
      stub.stub("eth_call", UncleBlockGiven::RpcError.from_payload({ "code" => 3, "message" => "execution reverted", "data" => data }))

      expect { usdc.simulate(:transfer, to: OTHER_ADDRESS, amount: 10) }.to raise_error(UncleBlockGiven::ContractRevertError) do |e|
        expect(e.error_name).to eq("ERC20InsufficientBalance")
        expect(e.args).to eq(sender: TEST_ADDRESS, balance: 5, needed: 10)
        expect(e.message).to eq("ERC20InsufficientBalance(\"#{TEST_ADDRESS}\", 5, 10)")
      end
    end
  end

  describe "writes" do
    it "signs and broadcasts, returning a Transaction that can wait for its receipt" do
      receipt = { "transactionHash" => "0x#{'ab' * 32}", "blockNumber" => "0x11", "status" => "0x1", "gasUsed" => "0x5208",
                  "logs" => [{ "address" => USDC_BASE.downcase, "topics" => [transfer_topic, word(TEST_ADDRESS), word(OTHER_ADDRESS)],
                               "data" => word(1_000_000), "blockNumber" => "0x11", "logIndex" => "0x0" }] }
      stub.stub("eth_getTransactionReceipt", UncleBlockGiven::Connectors::Stub.sequence(nil, receipt))

      tx = usdc.transfer(to: OTHER_ADDRESS, amount: 1e6)
      expect(tx).to be_a(UncleBlockGiven::Transaction)

      sent = Eth::Tx.decode(stub.calls_for("eth_sendRawTransaction").last.first)
      expect(sent.destination.downcase).to eq(UncleBlockGiven::Utils.strip_hex(USDC_BASE).downcase)
      expect("0x#{sent.payload.unpack1('H*')}").to eq(usdc.encode_function_data(:transfer, OTHER_ADDRESS, 1_000_000))
      expect(sent.gas_limit).to eq(60_000)

      result = tx.wait!
      expect(result.success?).to be true
      events = usdc.events_from(result)
      expect(events.map(&:name)).to eq(["Transfer"])
      expect(events.first.args).to eq(from: TEST_ADDRESS, to: OTHER_ADDRESS, value: 1_000_000)
    end

    it "passes tx overrides to the wallet" do
      usdc.approve(OTHER_ADDRESS, 1, tx: { gas: 80_000, nonce: 12, max_fee_per_gas: 100, max_priority_fee_per_gas: 1 })
      sent = Eth::Tx.decode(stub.calls_for("eth_sendRawTransaction").last.first)
      expect(sent.gas_limit).to eq(80_000)
      expect(sent.signer_nonce).to eq(12)
      expect(sent.max_fee_per_gas).to eq(100)
    end

    it "requires a wallet" do
      expect { TestERC20.at(USDC_BASE).transfer(OTHER_ADDRESS, 1) }.to raise_error(UncleBlockGiven::WalletRequiredError)
      expect { TestERC20.at(USDC_BASE).prepare_write(:transfer, OTHER_ADDRESS, 1) }.to raise_error(UncleBlockGiven::WalletRequiredError)
    end

    it "prepares a signed transaction whose hash is known before broadcasting" do
      stub.stub("eth_sendRawTransaction", ->(params) { UncleBlockGiven::Utils.keccak256(params.first) })
      signed = usdc.prepare_write(:transfer, to: OTHER_ADDRESS, amount: 1e6, tx: { nonce: 42 })

      expect(signed).to be_a(UncleBlockGiven::SignedTransaction)
      expect(signed.nonce).to eq(42)
      expect(signed.to).to eq(USDC_BASE)
      expect(signed.data).to eq(usdc.encode_function_data(:transfer, OTHER_ADDRESS, 1_000_000))
      expect(stub.calls_for("eth_sendRawTransaction")).to be_empty

      tx = signed.broadcast
      expect(tx.hash).to eq(signed.hash)
      expect(stub.calls_for("eth_sendRawTransaction")).to eq([[signed.raw]])
      expect { usdc.prepare_write(:transfer, OTHER_ADDRESS, 1, tx: { value: 1 }) }.to raise_error(UncleBlockGiven::InvalidArgumentError, /not payable/)
    end

    it "decodes custom errors raised while broadcasting a prepared transaction" do
      selector = UncleBlockGiven::Utils.keccak256("ERC20InsufficientBalance(address,uint256,uint256)")[0, 10]
      revert_data = selector + UncleBlockGiven::Utils.strip_hex(abi_encode(%w[address uint256 uint256], [TEST_ADDRESS, 5, 1_000_000]))
      signed = usdc.prepare_write(:transfer, to: OTHER_ADDRESS, amount: 1e6, tx: { gas: 60_000 })
      stub.stub("eth_sendRawTransaction",
                UncleBlockGiven::RpcError.from_payload({ "code" => 3, "message" => "execution reverted", "data" => revert_data }, rpc_method: "eth_sendRawTransaction"))

      expect { signed.broadcast }.to raise_error(UncleBlockGiven::ContractRevertError) do |e|
        expect(e.error_name).to eq("ERC20InsufficientBalance")
        expect(e.args).to include(needed: 1_000_000)
      end
      expect { signed.replacement }.not_to raise_error
    end

    it "refuses to send value to non payable functions and unknown tx options" do
      expect { usdc.transfer(OTHER_ADDRESS, 1, tx: { value: 1 }) }.to raise_error(UncleBlockGiven::InvalidArgumentError, /not payable/)
      expect { usdc.transfer(OTHER_ADDRESS, 1, tx: { gasLimit: 1 }) }.to raise_error(UncleBlockGiven::InvalidArgumentError, /unknown tx option/)
    end

    it "estimates gas for a call" do
      expect(usdc.estimate_gas(:transfer, to: OTHER_ADDRESS, amount: 1)).to eq(50_000)
    end
  end

  describe "events" do
    let(:log) do
      { "address" => USDC_BASE.downcase, "topics" => [transfer_topic, word(TEST_ADDRESS), word(OTHER_ADDRESS)],
        "data" => word(42), "blockNumber" => "0x10", "logIndex" => "0x2", "transactionHash" => "0x#{'cd' * 32}" }
    end

    it "fetches past events with indexed filters" do
      stub.stub("eth_getLogs", [log])
      events = usdc.get_events(:Transfer, from_block: 10, args: { to: OTHER_ADDRESS })
      expect(stub.calls_for("eth_getLogs").last.first)
        .to eq(address: USDC_BASE, topics: [transfer_topic, nil, word(OTHER_ADDRESS).downcase], fromBlock: "0xa", toBlock: "latest")
      expect(events.first.args).to eq(from: TEST_ADDRESS, to: OTHER_ADDRESS, value: 42)
      expect(events.first.transaction_hash).to eq("0x#{'cd' * 32}")
    end

    it "fetches all events of the contract when no name is given" do
      stub.stub("eth_getLogs", [log, log.merge("topics" => ["0x#{'ff' * 32}"])])
      events = usdc.get_events(from_block: 1)
      expect(stub.calls_for("eth_getLogs").last.first).not_to have_key(:topics)
      expect(events.size).to eq(1) # unknown topic skipped
    end

    it "fetches events over a large range in chunks" do
      stub.stub("eth_getLogs", ->(params) { params.first[:fromBlock] == "0x1" ? [log] : [] })
      events = usdc.get_events(:Transfer, from_block: 1, to_block: 10, max_block_range: 4)
      expect(stub.calls_for("eth_getLogs").size).to eq(3)
      expect(events.size).to eq(1)
    end

    it "watches events with polling" do
      stub.stub("eth_blockNumber", UncleBlockGiven::Connectors::Stub.sequence("0x10", "0x11", "0x11"))
      stub.stub("eth_getLogs", [log])
      seen = []
      watcher = usdc.watch_event(:Transfer) { |event| seen << event }
      deadline = Time.now + 1
      sleep 0.01 until seen.any? || Time.now > deadline
      watcher.unwatch.join(1)
      expect(seen.first.name).to eq("Transfer")
      expect(seen.first[:value]).to eq(42)
    end
  end
end
