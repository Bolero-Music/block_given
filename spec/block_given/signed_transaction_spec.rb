# frozen_string_literal: true

RSpec.describe BlockGiven::SignedTransaction do
  let(:stub) { build_stub }
  let(:wallet) { BlockGiven::Wallet.new(private_key: TEST_PRIVATE_KEY) }
  let(:signed) { wallet.signed_transaction(to: OTHER_ADDRESS, value: 10**15, gas: 21_000) }

  before { configure_block_given(stub) }

  it "knows its hash and nonce before any broadcast" do
    expect(signed.hash).to eq("0x#{Eth::Tx.decode(signed.raw).hash}")
    expect(signed.hash).to eq(BlockGiven::Utils.keccak256(signed.raw))
    expect(signed.nonce).to eq(5)
    expect(signed.from).to eq(TEST_ADDRESS)
    expect(signed.to).to eq(OTHER_ADDRESS)
    expect(signed.value).to eq(10**15)
    expect(signed.gas).to eq(21_000)
    expect(signed.chain_id).to eq(8453)
    expect(signed).not_to be_legacy
    expect(stub.calls_for("eth_sendRawTransaction")).to be_empty
  end

  it "broadcasts the raw bytes and returns a Transaction with the local hash" do
    stub.stub("eth_sendRawTransaction", ->(params) { BlockGiven::Utils.keccak256(params.first) })

    tx = signed.broadcast
    expect(tx).to be_a(BlockGiven::Transaction)
    expect(tx.hash).to eq(signed.hash)
    expect(stub.calls_for("eth_sendRawTransaction")).to eq([[signed.raw]])
    expect(signed.transaction).to eq(tx)
  end

  it "warns when the node returns another hash but keeps the local one" do
    log = StringIO.new
    BlockGiven.config.logger = Logger.new(log)
    stub.stub("eth_sendRawTransaction", "0x#{'cd' * 32}")

    expect(signed.submit.hash).to eq(signed.hash)
    expect(log.string).to include("node returned 0x#{'cd' * 32}")
  end

  describe "#replacement" do
    it "keeps payload and nonce, bumps both EIP-1559 fees by the multiplier" do
      replacement = signed.replacement
      decoded = Eth::Tx.decode(replacement.raw)

      expect(replacement.hash).not_to eq(signed.hash)
      expect(replacement.nonce).to eq(signed.nonce)
      expect(replacement.to).to eq(signed.to)
      expect(replacement.value).to eq(signed.value)
      expect(replacement.gas).to eq(signed.gas)
      expect(replacement.max_fee_per_gas).to eq((signed.max_fee_per_gas * 1.125).ceil)
      expect(replacement.max_priority_fee_per_gas).to eq((signed.max_priority_fee_per_gas * 1.125).ceil)
      expect(decoded.signer_nonce).to eq(5)
      expect(decoded.sender.downcase).to eq(BlockGiven::Utils.strip_hex(TEST_ADDRESS).downcase)
      expect(decoded.max_fee_per_gas).to eq(replacement.max_fee_per_gas)
    end

    it "never goes below a fresh fee estimate from the node" do
      expect(signed.max_priority_fee_per_gas).to eq(1_000_000) # signed while the node quoted 0.001 gwei
      stub.stub("eth_maxPriorityFeePerGas", "0x#{(10**9).to_s(16)}") # priority now 1 gwei
      replacement = signed.replacement(fee_multiplier: 1.1)

      expect(replacement.max_priority_fee_per_gas).to eq(10**9)
      expect(replacement.max_fee_per_gas).to be >= replacement.max_priority_fee_per_gas
    end

    it "bumps gas_price for legacy transactions" do
      legacy = wallet.signed_transaction(to: OTHER_ADDRESS, gas: 21_000, gas_price: 10**9)
      replacement = legacy.replacement(fee_multiplier: 1.5)

      expect(legacy).to be_legacy
      expect(replacement.gas_price).to eq(1_500_000_000)
      expect(Eth::Tx.decode(replacement.raw)).to be_a(Eth::Tx::Legacy)
    end

    it "refuses multipliers the node would reject" do
      expect { signed.replacement(fee_multiplier: 1.05) }
        .to raise_error(BlockGiven::InvalidArgumentError, /fee_multiplier must be >= 1.1/)
    end
  end

  describe ".from_raw" do
    it "rebuilds an EIP-1559 transaction from persisted bytes, ready to be replaced" do
      rebuilt = described_class.from_raw(signed.raw, wallet: wallet)

      expect(rebuilt).to eq(signed)
      expect(rebuilt.hash).to eq(signed.hash)
      expect(rebuilt.params).to eq(signed.params)
      expect(rebuilt.replacement.nonce).to eq(5)
    end

    it "rebuilds a legacy transaction with calldata" do
      legacy = wallet.signed_transaction(to: OTHER_ADDRESS, data: "0xa9059cbb", gas: 60_000, gas_price: 10**9)
      rebuilt = described_class.from_raw(BlockGiven::Utils.strip_hex(legacy.raw), wallet: wallet)

      expect(rebuilt.params).to eq(legacy.params)
      expect(rebuilt).to be_legacy
      expect(rebuilt.data).to eq("0xa9059cbb")
    end

    it "refuses bytes signed by another key or undecodable bytes" do
      other = BlockGiven::Wallet.generate
      expect { described_class.from_raw(signed.raw, wallet: other) }
        .to raise_error(BlockGiven::InvalidArgumentError, /not by wallet #{other.address}/)
      expect { described_class.from_raw("0x02deadbeef", wallet: wallet) }
        .to raise_error(BlockGiven::InvalidArgumentError, /cannot decode/)
    end
  end

  it "refuses to replace a transaction rebuilt without fee params" do
    bare = described_class.new(raw: signed.raw, params: { nonce: 5 }, wallet: wallet)
    expect { bare.replacement }.to raise_error(BlockGiven::InvalidArgumentError, /without fee params/)
  end

  it "serializes for persistence and hides nothing sensitive" do
    expect(signed.to_h).to include(hash: signed.hash, raw: signed.raw, nonce: 5, to: OTHER_ADDRESS)
    expect(signed.inspect).to eq("#<BlockGiven::SignedTransaction #{signed.hash} nonce=5 to=#{OTHER_ADDRESS}>")
    expect(signed.inspect).not_to include("ac0974")
    expect(signed.to_s).to eq(signed.hash)
    expect(signed).to eq(BlockGiven::SignedTransaction.new(raw: signed.raw, params: {}, wallet: wallet))
  end
end
