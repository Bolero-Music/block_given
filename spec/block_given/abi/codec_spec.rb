# frozen_string_literal: true

RSpec.describe BlockGiven::Abi::Codec do
  # eth returns bytes and strings alike as binary Strings, which the fixture stores as hex.
  def readable(type, value)
    return value.map { |v| readable(type.element, v) } if type.array?
    return type.components.zip(value).map { |t, v| readable(t, v) } if type.base == "tuple"

    %w[bytes string].include?(type.base) ? BlockGiven::Utils.bin_to_hex(value.b) : value
  end

  it "encodes and decodes like eth: integers at their bounds, bytes, strings, fixed, dynamic and nested arrays, tuples" do
    expect(GOLDEN["abi"].size).to be >= 30
    GOLDEN["abi"].each do |vector|
      encoded = described_class.encode(vector["types"], vector["values"])
      expect(BlockGiven::Utils.bin_to_hex(encoded)).to eq(vector["encoded"]), vector["types"].join(",")
      decoded = described_class.decode(vector["types"], BlockGiven::Utils.hex_to_bin(vector["encoded"]))
      types = vector["types"].map { |t| BlockGiven::Abi::Type.parse(t) }
      expect(types.zip(decoded).map { |t, v| readable(t, v) }).to eq(vector["decoded"]), vector["types"].join(",")
    end
  end

  it "encodes a String as text even when it looks like hex, and bytes given as binary" do
    expect(described_class.decode(["string"], described_class.encode(["string"], ["0x1234"]))).to eq(["0x1234"])
    expect(described_class.encode(["bytes2"], ["\x01\x02".b])).to eq(described_class.encode(["bytes2"], ["0x0102"]))
  end

  it "rejects values that do not fit their type" do
    {
      ["uint8", 256] => /out of bounds for uint8/, ["uint256", -1] => /out of bounds/, ["int8", -129] => /out of bounds/,
      %w[uint256 1] => /expects an Integer/, ["bool", 1] => %r{true/false}, %w[address 0x12] => /invalid address/,
      %w[bytes2 0x010203] => /bytes are out of bounds for bytes2/, %w[bytes 0x123] => /even number/, ["bytes", 1] => /String/,
      ["string", 1] => /String/, ["uint256[2]", [1]] => /2 elements/, ["uint256[]", 1] => /Array/,
      ["(uint256,bool)", [1]] => /Array of 2 values/
    }.each do |(type, value), error|
      expect { described_class.encode([type], [value]) }.to raise_error(BlockGiven::AbiEncodingError, error), type
    end
    expect { described_class.encode(%w[uint256 uint256], [1]) }.to raise_error(BlockGiven::AbiEncodingError, /2 value/)
  end

  it "rejects unsupported or malformed types" do
    %w[fixed128x18 function uint7 uint264 bytes33 bytes0 address2 (uint256 (uint256)x tuple(uint256 foo].each do |type|
      expect { BlockGiven::Abi::Type.parse(type) }.to raise_error(BlockGiven::AbiError, /unsupported ABI type/), type
    end
    expect(BlockGiven::Abi::Type.parse("tuple(uint,int,(bytes,string)[])[2][]").to_s)
      .to eq("(uint256,int256,(bytes,string)[])[2][]")
    expect(BlockGiven::Abi::Type.parse("()").components).to eq([])
  end

  it "rejects truncated data and offsets or lengths pointing outside of it" do
    word = ->(n) { [n.to_s(16).rjust(64, "0")].pack("H*") }
    {
      [["uint256"], "".b] => /not enough data/,
      [["string"], word.call(1000)] => /outside of the data/,
      [["bytes"], word.call(32) + word.call(5)] => /not enough data/,
      [["uint256[]"], word.call(32) + word.call(2**64)] => /exceeds the data/,
      [["uint256[]"], word.call(32) + word.call(2) + word.call(1)] => /exceeds the data/
    }.each do |(types, data), error|
      expect { described_class.decode(types, data) }.to raise_error(BlockGiven::AbiDecodingError, error)
    end
  end

  it "is what Coder uses, with its errors prefixed" do
    function = BlockGiven::Abi::Interface.new(JSON.parse(File.read(File.join(FIXTURES, "erc20.json")))).function(:balance_of)
    expect { function.decode_output("0x1234") }.to raise_error(BlockGiven::AbiDecodingError, /ABI decoding failed: not enough data/)
    expect { function.decode_output("0xzz") }.to raise_error(BlockGiven::AbiDecodingError, /ABI decoding failed: data is not hex/)
    expect { function.encode(["0x#{'1' * 40}"]) }.not_to raise_error
  end
end
