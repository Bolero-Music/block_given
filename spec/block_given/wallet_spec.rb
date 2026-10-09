# frozen_string_literal: true

RSpec.describe BlockGiven::Wallet do
  let(:stub) { build_stub }

  before { configure_block_given(stub) }

  it "derives the address from the private key" do
    wallet = described_class.new(private_key: TEST_PRIVATE_KEY)
    expect(wallet.address).to eq(TEST_ADDRESS)
    expect(described_class.new(private_key: BlockGiven::Utils.strip_hex(TEST_PRIVATE_KEY)).address).to eq(TEST_ADDRESS)
  end

  it "rejects malformed keys and hides the key in inspect" do
    expect { described_class.new(private_key: "0x1234") }.to raise_error(BlockGiven::InvalidArgumentError)
    expect { described_class.new(private_key: "0x#{'00' * 32}") }.to raise_error(BlockGiven::InvalidArgumentError, /range/)
    order = BlockGiven::Crypto::Secp256k1::N.to_s(16)
    expect { described_class.new(private_key: order) }.to raise_error(BlockGiven::InvalidArgumentError, /range/)
    expect(described_class.new(private_key: TEST_PRIVATE_KEY).inspect).not_to include("ac0974")
  end

  it "generates random wallets" do
    a = described_class.generate
    b = described_class.generate
    expect(a.address).not_to eq(b.address)
    expect(BlockGiven::Utils.address?(a.address)).to be true
    expect(described_class.new(private_key: a.private_key)).to eq(a)
  end

  it "exposes the keys eth derived" do
    GOLDEN["keys"].each do |vector|
      wallet = described_class.new(private_key: vector["private_key"])
      expect(wallet.address).to eq(vector["address"])
      expect(wallet.public_key).to eq(vector["public_key"])
      expect(wallet.private_key).to eq(vector["private_key"])
    end
  end

  it "signs messages (EIP-191) like eth, empty, multi-byte and long messages included" do
    signature = described_class.new(private_key: TEST_PRIVATE_KEY).sign_message("hello")
    expect(signature).to match(/\A0x[0-9a-f]{130}\z/)
    GOLDEN["personal_sign"].each do |vector|
      expect(described_class.new(private_key: vector["private_key"]).sign_message(vector["message"])).to eq(vector["signature"])
    end
  end

  describe "#prepare_transaction" do
    let(:wallet) { described_class.new(private_key: TEST_PRIVATE_KEY) }

    it "fills nonce, gas (with multiplier) and fees" do
      params = wallet.prepare_transaction(to: OTHER_ADDRESS, value: 1, data: "0xa9059cbb")
      expect(params).to include(
        from: TEST_ADDRESS, to: OTHER_ADDRESS, chain_id: 8453, nonce: 5, value: 1, data: "0xa9059cbb",
        gas: (50_000 * 1.2).ceil, max_priority_fee_per_gas: 1_000_000, max_fee_per_gas: 1_201_000_000
      )
      expect(stub.calls_for("eth_estimateGas").last)
        .to eq([{ to: OTHER_ADDRESS, data: "0xa9059cbb", from: TEST_ADDRESS, value: "0x1" }])
    end

    it "keeps explicit overrides and skips the corresponding RPC calls" do
      params = wallet.prepare_transaction(to: OTHER_ADDRESS, gas: 21_000, nonce: 9,
                                          max_fee_per_gas: 10, max_priority_fee_per_gas: 1)
      expect(params).to include(gas: 21_000, nonce: 9, max_fee_per_gas: 10, max_priority_fee_per_gas: 1)
      expect(stub.calls.map(&:first)).not_to include("eth_estimateGas", "eth_getTransactionCount", "eth_getBlockByNumber")
    end

    it "rejects fractional wei" do
      expect { wallet.prepare_transaction(to: OTHER_ADDRESS, value: 1.5) }.to raise_error(BlockGiven::InvalidArgumentError)
    end
  end

  describe "#send_transaction" do
    let(:wallet) { described_class.new(private_key: TEST_PRIVATE_KEY) }

    it "signs an EIP-1559 transaction the node can recover" do
      tx = wallet.send_transaction(to: OTHER_ADDRESS, value: 10**15, gas: 21_000)
      expect(tx).to be_a(BlockGiven::Transaction)

      raw = stub.calls_for("eth_sendRawTransaction").last.first
      expect(tx.hash).to eq(BlockGiven::Utils.keccak256(raw)) # local hash, not the node's answer
      expect(raw).to start_with("0x02")
      decoded = BlockGiven::TransactionEnvelope.decode(raw)
      expect(decoded).to include(from: TEST_ADDRESS, to: OTHER_ADDRESS, value: 10**15, chain_id: 8453, nonce: 5)
    end

    it "goes through a SignedTransaction whose hash matches the raw bytes" do
      signed = wallet.signed_transaction(to: OTHER_ADDRESS, value: 1, gas: 21_000)
      expect(signed).to be_a(BlockGiven::SignedTransaction)
      expect(wallet.sign_transaction(to: OTHER_ADDRESS, value: 1, gas: 21_000)).to eq(signed.raw)
      expect(stub.calls_for("eth_sendRawTransaction")).to be_empty
    end

    it "builds a legacy transaction when gas_price is given" do
      wallet.send_transaction(to: OTHER_ADDRESS, gas: 21_000, gas_price: 10**9)
      raw = stub.calls_for("eth_sendRawTransaction").last.first
      expect(raw).not_to start_with("0x02")
      expect(BlockGiven::TransactionEnvelope.decode(raw)).to include(gas_price: 10**9, from: TEST_ADDRESS)
    end
  end
end
