# frozen_string_literal: true

RSpec.describe BlockGiven::Rlp do
  def hex(bin) = bin.unpack1("H*")

  it "encodes the reference examples" do
    expect(hex(described_class.encode("dog"))).to eq("83646f67")
    expect(hex(described_class.encode(%w[cat dog]))).to eq("c88363617483646f67")
    expect(hex(described_class.encode(""))).to eq("80")
    expect(hex(described_class.encode([]))).to eq("c0")
    expect(hex(described_class.encode(0))).to eq("80")
    expect(hex(described_class.encode("\x00"))).to eq("00")
    expect(hex(described_class.encode(15))).to eq("0f")
    expect(hex(described_class.encode(1024))).to eq("820400")
    expect(hex(described_class.encode([[], [[]], [[], [[]]]]))).to eq("c7c0c1c0c3c0c1c0")
    lorem = "Lorem ipsum dolor sit amet, consectetur adipisicing elit"
    expect(hex(described_class.encode(lorem))).to eq("b838#{hex(lorem)}")
    expect(hex(described_class.encode(["a" * 60]))).to eq("f83eb83c#{'61' * 60}")
  end

  it "round-trips nested items" do
    item = ["dog".b, ["".b, "\x7f".b, "\x80".b, ("x" * 1024).b], [[]]]
    expect(described_class.decode(described_class.encode(item))).to eq(item)
  end

  it "reads integers" do
    expect(described_class.to_int("".b)).to eq(0)
    expect(described_class.to_int("\x04\x00".b)).to eq(1024)
    expect { described_class.to_int("\x00\x01".b) }.to raise_error(BlockGiven::InvalidArgumentError, /leading zero/)
    expect { described_class.to_int([]) }.to raise_error(BlockGiven::InvalidArgumentError, /list/)
  end

  it "rejects malformed input" do
    expect { described_class.encode(-1) }.to raise_error(BlockGiven::InvalidArgumentError, /negative/)
    expect { described_class.encode(1.5) }.to raise_error(BlockGiven::InvalidArgumentError, /Float/)
    {
      "" => /end of input/, "83646f" => /end of input/, "83646f6700" => /trailing/, "8105" => /single byte/,
      "b801" => /non-canonical length/, "b9" => /end of input/, "c2830102" => /end of input/,
      "c1c2c0c0" => /overflows|trailing|end of input/
    }.each do |input, error|
      expect { described_class.decode([input].pack("H*")) }.to raise_error(BlockGiven::InvalidArgumentError, error)
    end
  end
end
