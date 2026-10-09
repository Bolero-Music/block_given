# frozen_string_literal: true

RSpec.describe BlockGiven::Crypto::Secp256k1 do
  let(:hash) { BlockGiven::Crypto::Keccak.digest("block_given") }

  it "derives the public key and address eth derived, edge keys (1, n - 1) included" do
    GOLDEN["keys"].each do |vector|
      public_key = described_class.public_key(vector["private_key"].to_i(16))
      expect(BlockGiven::Utils.bin_to_hex(public_key)).to eq(vector["public_key"])
      expect(BlockGiven::Crypto.address(public_key)).to eq(vector["address"])
    end
  end

  it "signs deterministically with a low s and a recovery id that recovers the key" do
    GOLDEN["keys"].each do |vector|
      key = vector["private_key"].to_i(16)
      r, s, recovery_id = described_class.sign(hash, key)

      expect(described_class.sign(hash, key)).to eq([r, s, recovery_id])
      expect(s).to be <= described_class::HALF_N
      expect(described_class.recover(hash, r, s, recovery_id)).to eq(described_class.public_key(key))
    end
  end

  it "generates keys in range" do
    keys = Array.new(5) { described_class.generate_private_key }
    expect(keys).to all(satisfy { |k| described_class.valid_private_key?(k) })
    expect(keys.uniq.size).to eq(5)
  end

  it "validates the key range" do
    expect(described_class.valid_private_key?(0)).to be false
    expect(described_class.valid_private_key?(described_class::N)).to be false
    expect(described_class.valid_private_key?(described_class::N - 1)).to be true
    expect(described_class.valid_private_key?("1")).to be false
  end

  it "rejects signatures that recover nothing" do
    r, s, = described_class.sign(hash, 1)
    expect { described_class.recover(hash, 0, s, 0) }.to raise_error(BlockGiven::InvalidArgumentError)
    expect { described_class.recover(hash, r, described_class::N, 0) }.to raise_error(BlockGiven::InvalidArgumentError)
    expect { described_class.recover(hash, r, s, 4) }.to raise_error(BlockGiven::InvalidArgumentError)
    expect { described_class.recover(hash, r, s, 2) }.to raise_error(BlockGiven::InvalidArgumentError) # x >= p
    # 5 is not the X coordinate of any curve point
    expect { described_class.recover(hash, 5, s, 0) }.to raise_error(BlockGiven::InvalidArgumentError)
  end

  it "skips RFC 6979 candidates outside [1, n - 1] and moves on to the next one" do
    key = "\x01".b * 32
    message = "\x02".b * 32
    expected = described_class.nonces(key, message).first(2)
    allow(described_class).to receive(:valid_private_key?).and_return(false, true)

    expect(described_class.nonces(key, message).first).to eq(expected.last)
  end
end
