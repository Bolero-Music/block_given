# frozen_string_literal: true

RSpec.describe BlockGiven::TransactionEnvelope do
  def params_from(vector)
    params = {
      to: vector["to"], value: vector["value"], data: vector["data"].to_s, chain_id: vector["chain_id"],
      nonce: vector["nonce"], gas: vector["gas"], access_list: vector["access_list"]
    }
    if vector["type"].zero?
      params.merge(gas_price: vector["gas_price"])
    else
      params.merge(max_fee_per_gas: vector["max_fee_per_gas"], max_priority_fee_per_gas: vector["max_priority_fee_per_gas"])
    end
  end

  let(:key) { TEST_PRIVATE_KEY.to_i(16) }
  let(:base) do
    { to: OTHER_ADDRESS, value: 1, data: "", chain_id: 8453, nonce: 0, gas: 21_000,
      max_fee_per_gas: 2, max_priority_fee_per_gas: 1 }
  end

  it "signs EIP-1559 and legacy (EIP-155) transactions byte for byte like eth, creations included" do
    expect(GOLDEN["transactions"].map { |v| v["type"] }.tally).to eq(0 => 8, 2 => 9)
    GOLDEN["transactions"].each do |vector|
      raw = described_class.sign(params_from(vector), vector["private_key"].to_i(16))

      expect(raw).to eq(vector["raw"]), "#{vector['type']} on chain #{vector['chain_id']}"
      expect(BlockGiven::Utils.keccak256(raw)).to eq(vector["hash"])
    end
  end

  it "decodes every vector back to its parameters and sender" do
    GOLDEN["transactions"].each do |vector|
      decoded = described_class.decode(vector["raw"])
      expected = params_from(vector)
      expected[:to] = expected[:to] && BlockGiven::Utils.checksum_address(expected[:to])
      expected[:data] = "" if expected[:data] == "0x"
      expected[:access_list] = expected[:access_list]&.map do |address, keys|
        { address: BlockGiven::Utils.checksum_address(address), storage_keys: keys }
      end
      expected[:access_list] = nil if expected[:access_list] && expected[:access_list].empty?

      expect(decoded).to eq(expected.merge(from: vector["from"]))
    end
  end

  it "accepts access lists as hashes (snake_case, camelCase or String keys) and pads storage keys" do
    pairs = [[USDC_BASE, ["0x#{'00' * 31}01"]]]
    hashes = [{ "address" => USDC_BASE.downcase, "storageKeys" => ["0x1"] }]
    from_pairs = described_class.sign(base.merge(gas: 30_000, access_list: pairs), key)

    expect(described_class.sign(base.merge(gas: 30_000, access_list: hashes), key)).to eq(from_pairs)
    expect(described_class.decode(from_pairs)[:access_list])
      .to eq([{ address: USDC_BASE, storage_keys: ["0x#{'00' * 31}01"] }])
    expect { described_class.sign(base.merge(gas: 30_000, access_list: ["nope"]), key) }
      .to raise_error(BlockGiven::InvalidArgumentError, /access list entry/)
  end

  it "rejects fields no node would accept, before signing" do
    expect { described_class.sign(base.merge(nonce: -1), key) }.to raise_error(BlockGiven::InvalidArgumentError, /nonce/)
    expect { described_class.sign(base.merge(value: nil), key) }.to raise_error(BlockGiven::InvalidArgumentError, /value/)
    expect { described_class.sign(base.merge(max_fee_per_gas: -1), key) }
      .to raise_error(BlockGiven::InvalidArgumentError, /max_fee_per_gas/)
    expect { described_class.sign(base.merge(chain_id: 0), key) }.to raise_error(BlockGiven::InvalidArgumentError, /chain_id/)
    expect { described_class.sign(base.merge(gas: 20_999), key) }
      .to raise_error(BlockGiven::InvalidArgumentError, /below the intrinsic gas of the transaction \(21000\)/)
    # 4 bytes of calldata, one of them zero: 21000 + 3 * 16 + 4
    expect { described_class.sign(base.merge(data: "0xa9059c00", gas: 21_051), key) }
      .to raise_error(BlockGiven::InvalidArgumentError, /\(21052\)/)
    # creation: + 32000 and 2 per init code word
    expect { described_class.sign(base.merge(to: nil, data: "0x00", gas: 53_005), key) }
      .to raise_error(BlockGiven::InvalidArgumentError, /\(53006\)/)
    expect { described_class.sign(base.merge(gas: 25_299, access_list: [[USDC_BASE, ["0x01"]]]), key) }
      .to raise_error(BlockGiven::InvalidArgumentError, /\(25300\)/)
  end

  it "decodes a legacy transaction signed without replay protection (v = 27 or 28)" do
    fields = [1, 10**9, 21_000, BlockGiven::Utils.hex_to_bin(OTHER_ADDRESS), 5, "".b]
    r, s, recovery_id = BlockGiven::Crypto::Secp256k1.sign(BlockGiven::Crypto::Keccak.digest(BlockGiven::Rlp.encode(fields)), key)
    raw = BlockGiven::Utils.bin_to_hex(BlockGiven::Rlp.encode(fields + [27 + recovery_id, r, s]))

    expect(described_class.decode(raw)).to include(from: TEST_ADDRESS, chain_id: nil, nonce: 1, gas_price: 10**9, value: 5)
  end

  it "rejects bytes that are not a signed transaction" do
    {
      "" => /empty/, "0xzz" => /hex/, "0x123" => /hex/, "0x01c0" => /unsupported transaction type 1/,
      "0x02c0" => /12 fields/, "0xc0" => /9 fields/, "0x02c3010203" => /12 fields/
    }.each do |raw, error|
      expect { described_class.decode(raw) }.to raise_error(BlockGiven::InvalidArgumentError, error), raw
    end
  end

  it "rejects invalid signature values" do
    raw = described_class.sign(base, key)
    fields = BlockGiven::Rlp.decode(BlockGiven::Utils.hex_to_bin(raw).byteslice(1..))
    tampered = ->(index, value) { "0x02#{BlockGiven::Rlp.encode(fields.dup.tap { |f| f[index] = value }).unpack1('H*')}" }

    expect { described_class.decode(tampered.call(9, 2)) }.to raise_error(BlockGiven::InvalidArgumentError, /y parity/)
    expect { described_class.decode(tampered.call(5, "\x01".b)) }.to raise_error(BlockGiven::InvalidArgumentError, /destination/)
    expect { described_class.decode(tampered.call(7, [])) }.to raise_error(BlockGiven::InvalidArgumentError, /data/)
    expect { described_class.decode(tampered.call(8, "x")) }.to raise_error(BlockGiven::InvalidArgumentError, /access list/)
    expect { described_class.decode(tampered.call(8, [["x"]])) }.to raise_error(BlockGiven::InvalidArgumentError, /access list/)

    legacy = BlockGiven::Rlp.decode(BlockGiven::Utils.hex_to_bin(described_class.sign(base.merge(gas_price: 1), key)))
    legacy[6] = 30
    expect { described_class.decode(BlockGiven::Utils.bin_to_hex(BlockGiven::Rlp.encode(legacy))) }
      .to raise_error(BlockGiven::InvalidArgumentError, /invalid legacy signature v 30/)
  end
end
