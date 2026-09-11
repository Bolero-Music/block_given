# frozen_string_literal: true

RSpec.describe UncleBlockGiven::Wallet do
  let(:stub) { build_stub }

  before { configure_uncle_block_given(stub) }

  it "derives the address from the private key" do
    wallet = described_class.new(private_key: TEST_PRIVATE_KEY)
    expect(wallet.address).to eq(TEST_ADDRESS)
    expect(described_class.new(private_key: UncleBlockGiven::Utils.strip_hex(TEST_PRIVATE_KEY)).address).to eq(TEST_ADDRESS)
  end

  it "rejects malformed keys and hides the key in inspect" do
    expect { described_class.new(private_key: "0x1234") }.to raise_error(UncleBlockGiven::InvalidArgumentError)
    expect(described_class.new(private_key: TEST_PRIVATE_KEY).inspect).not_to include("ac0974")
  end

  it "generates random wallets" do
    a = described_class.generate
    b = described_class.generate
    expect(a.address).not_to eq(b.address)
    expect(UncleBlockGiven::Utils.address?(a.address)).to be true
  end

  it "signs messages (EIP-191)" do
    signature = described_class.new(private_key: TEST_PRIVATE_KEY).sign_message("hello")
    expect(signature).to match(/\A0x[0-9a-f]{130}\z/)
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
      expect { wallet.prepare_transaction(to: OTHER_ADDRESS, value: 1.5) }.to raise_error(UncleBlockGiven::InvalidArgumentError)
    end
  end

  describe "#send_transaction" do
    let(:wallet) { described_class.new(private_key: TEST_PRIVATE_KEY) }

    it "signs an EIP-1559 transaction the node can recover" do
      tx = wallet.send_transaction(to: OTHER_ADDRESS, value: 10**15, gas: 21_000)
      expect(tx).to be_a(UncleBlockGiven::Transaction)
      expect(tx.hash).to eq("0x#{'ab' * 32}")

      raw = stub.calls_for("eth_sendRawTransaction").last.first
      expect(raw).to start_with("0x02")
      decoded = Eth::Tx.decode(raw)
      expect(decoded.sender.downcase).to eq(UncleBlockGiven::Utils.strip_hex(TEST_ADDRESS).downcase)
      expect(decoded.destination.downcase).to eq(UncleBlockGiven::Utils.strip_hex(OTHER_ADDRESS).downcase)
      expect(decoded.amount).to eq(10**15)
      expect(decoded.chain_id).to eq(8453)
      expect(decoded.signer_nonce).to eq(5)
    end

    it "builds a legacy transaction when gas_price is given" do
      wallet.send_transaction(to: OTHER_ADDRESS, gas: 21_000, gas_price: 10**9)
      raw = stub.calls_for("eth_sendRawTransaction").last.first
      expect(Eth::Tx.decode(raw)).to be_a(Eth::Tx::Legacy)
    end
  end
end
