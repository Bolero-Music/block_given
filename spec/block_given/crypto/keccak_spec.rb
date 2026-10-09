# frozen_string_literal: true

RSpec.describe BlockGiven::Crypto::Keccak do
  it "uses the original Keccak padding, not NIST SHA3" do
    expect(described_class.digest("").unpack1("H*"))
      .to eq("c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
    expect(described_class.digest("Transfer(address,address,uint256)").unpack1("H*"))
      .to eq("ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef")
  end

  it "reproduces the eth vectors, rate boundaries (135, 136, 137 bytes) and multi-block inputs included" do
    GOLDEN["keccak"].each do |vector|
      expect(BlockGiven::Utils.bin_to_hex(described_class.digest(BlockGiven::Utils.hex_to_bin(vector["input"]))))
        .to eq(vector["digest"]), "keccak of #{vector['input'][0, 20]}..."
    end
  end

  it "hashes the bytes whatever the String encoding" do
    expect(described_class.digest("héllo")).to eq(described_class.digest("héllo".b))
  end
end
