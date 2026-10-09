# frozen_string_literal: true

RSpec.describe BlockGiven::Eip712 do
  let(:permit) { GOLDEN["typed_data"].find { |v| v["typed_data"]["primaryType"] == "Permit" }["typed_data"] }

  it "hashes and signs typed data like eth: nested structs, int, bool, bytes, bytesN, string, salt" do
    GOLDEN["typed_data"].each do |vector|
      expect(BlockGiven::Utils.bin_to_hex(described_class.hash(vector["typed_data"]))).to eq(vector["hash"])
      expect(BlockGiven::Wallet.new(private_key: vector["private_key"]).sign_typed_data(vector["typed_data"]))
        .to eq(vector["signature"])
    end
  end

  # eth 0.5.17 ABI-encodes arrays inline (and cannot parse struct arrays), which is not what EIP-712 specifies;
  # these hashes come from viem 2.43 hashTypedData.
  it "hashes arrays as the specification and viem do: atomic, string, bytes, struct, fixed and nested arrays" do
    simple = { types: { T: [{ name: "ids", type: "uint256[]" }] }, primaryType: "T", domain: { name: "B" },
               message: { ids: [1, 2] } }
    expect(BlockGiven::Utils.bin_to_hex(described_class.hash(simple)))
      .to eq("0xe79dca26d7dd77888515d25a739ff7ab41b335214968b7a2076fdb7c038e3b62")

    group = {
      domain: { name: "Bolero", version: "1", chainId: 8453 },
      types: {
        Person: [{ name: "name", type: "string" }, { name: "wallets", type: "address[]" }],
        Group: [{ name: "members", type: "Person[]" }, { name: "ids", type: "uint256[2]" }, { name: "tags", type: "string[]" },
                { name: "blobs", type: "bytes[]" }, { name: "grid", type: "uint8[][]" }]
      },
      primaryType: "Group",
      message: {
        members: [{ name: "a", wallets: [OTHER_ADDRESS] }, { name: "b", wallets: [] }],
        ids: [1, 2], tags: %w[x yz], blobs: %w[0x01 0x], grid: [[1, 2], [], [3]]
      }
    }
    expect(BlockGiven::Utils.bin_to_hex(described_class.hash(group)))
      .to eq("0x5ee877ee3cb7aaf1bc44bac9a60c2f9de1897804d1ade43d9cd2598b0de9ed5c")
  end

  it "accepts Symbol keys, String integers and a missing EIP712Domain" do
    expected = described_class.hash(permit)
    symbolized = JSON.parse(JSON.generate(permit), symbolize_names: true)
    symbolized[:message][:value] = "1000000"
    symbolized[:message][:deadline] = "0x6553f100"
    symbolized[:types].delete(:EIP712Domain)

    expect(described_class.hash(symbolized)).to eq(expected)
  end

  it "encodes the type with its dependencies sorted" do
    types = { "Mail" => [%w[from Person], %w[to Person[]], %w[contents string]],
              "Person" => [%w[name string], %w[wallet Wallet]], "Wallet" => [%w[addr address]] }
    expect(described_class.encode_type("Mail", types))
      .to eq("Mail(Person from,Person[] to,string contents)Person(string name,Wallet wallet)Wallet(address addr)")
  end

  it "rejects malformed payloads" do
    td = ->(**changes) { permit.merge(changes.transform_keys(&:to_s)) }
    message = permit["message"]
    {
      td.call(message: {}) => /message is missing/,
      td.call(primaryType: "Nope") => /unknown EIP-712 type Nope/,
      td.call(message: message.merge("owner" => "0x12")) => /invalid address/,
      td.call(message: message.merge("value" => -1)) => /does not fit in uint256/,
      td.call(message: message.merge("value" => 1.5)) => /expects an integer/,
      td.call(message: message.merge("value" => "abc")) => /expects an integer/,
      td.call(message: message.except("nonce")) => /Permit.nonce is missing/,
      td.call(message: "nope") => /expects a Hash/,
      td.call(types: permit["types"].merge("Permit" => [{ "name" => "x" }])) => /malformed field/
    }.each do |payload, error|
      expect { described_class.hash(payload) }.to raise_error(BlockGiven::InvalidArgumentError, error)
    end
  end

  it "validates atomic and array values" do
    expect { described_class.encode_atomic("bool", 1) }.to raise_error(BlockGiven::InvalidArgumentError, /expects true/)
    expect { described_class.encode_atomic("bytes2", "0x010203") }.to raise_error(BlockGiven::InvalidArgumentError, /too long/)
    expect { described_class.encode_atomic("bytes2", "zz") }.to raise_error(BlockGiven::InvalidArgumentError, /0x hex/)
    expect { described_class.encode_atomic("fixed128x18", 1) }.to raise_error(BlockGiven::InvalidArgumentError, /unknown/)
    expect { described_class.encode_atomic("int8", 128) }.to raise_error(BlockGiven::InvalidArgumentError, /int8/)
    expect(described_class.encode_atomic("int8", -1)).to eq("\xff".b * 32)
    expect { described_class.encode_field("uint8[2]", [1], {}) }.to raise_error(BlockGiven::InvalidArgumentError, /2 elements/)
    expect { described_class.encode_field("uint8[]", 1, {}) }.to raise_error(BlockGiven::InvalidArgumentError, /Array/)
  end
end
