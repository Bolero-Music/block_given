# frozen_string_literal: true

RSpec.describe BlockGiven::Abi::Interface do
  let(:abi) do
    [
      { "type" => "function", "name" => "transfer", "stateMutability" => "nonpayable",
        "inputs" => [{ "name" => "to", "type" => "address" }, { "name" => "amount", "type" => "uint256" }],
        "outputs" => [{ "name" => "", "type" => "bool" }] },
      { "type" => "function", "name" => "safeMint", "stateMutability" => "nonpayable",
        "inputs" => [{ "name" => "to", "type" => "address" }], "outputs" => [] },
      { "type" => "function", "name" => "safeMint", "stateMutability" => "nonpayable",
        "inputs" => [{ "name" => "to", "type" => "address" }, { "name" => "data", "type" => "bytes" }], "outputs" => [] },
      { "type" => "function", "name" => "getPosition", "stateMutability" => "view",
        "inputs" => [{ "name" => "id", "type" => "uint256" }],
        "outputs" => [{ "name" => "position", "type" => "tuple",
                        "components" => [{ "name" => "owner", "type" => "address" }, { "name" => "shares", "type" => "uint128" },
                                         { "name" => "tags", "type" => "string[]" }] }] },
      { "type" => "function", "name" => "batch", "stateMutability" => "payable",
        "inputs" => [{ "name" => "orders", "type" => "tuple[]",
                       "components" => [{ "name" => "tokenId", "type" => "uint256" }, { "name" => "price", "type" => "uint256" }] }],
        "outputs" => [{ "name" => "", "type" => "uint256" }, { "name" => "", "type" => "bool" }] },
      { "type" => "event", "name" => "Transfer", "anonymous" => false,
        "inputs" => [{ "indexed" => true, "name" => "from", "type" => "address" },
                     { "indexed" => true, "name" => "to", "type" => "address" },
                     { "indexed" => false, "name" => "value", "type" => "uint256" }] },
      { "type" => "event", "name" => "Named", "anonymous" => false,
        "inputs" => [{ "indexed" => true, "name" => "label", "type" => "string" },
                     { "indexed" => false, "name" => "id", "type" => "uint256" },
                     { "indexed" => false, "name" => "who", "type" => "address" }] },
      { "type" => "error", "name" => "Unauthorized", "inputs" => [{ "name" => "caller", "type" => "address" }] },
      { "type" => "constructor", "inputs" => [] }
    ]
  end
  let(:interface) { described_class.parse(abi) }

  it "parses functions, events, errors and constructor" do
    expect(interface.functions.size).to eq(5)
    expect(interface.events.map(&:name)).to eq(%w[Transfer Named])
    expect(interface.errors.first.selector).to eq(BlockGiven::Utils.keccak256("Unauthorized(address)")[0, 10])
    expect(interface.constructor).to include("type" => "constructor")
  end

  it "parses artifacts and JSON strings" do
    expect(described_class.parse({ "abi" => abi }).functions.size).to eq(5)
    expect(described_class.parse(abi.to_json).functions.size).to eq(5)
    expect { described_class.parse("nope") }.to raise_error(BlockGiven::AbiError)
  end

  describe "#function" do
    it "finds by snake_case, camelCase or signature" do
      expect(interface.function(:transfer).selector).to eq("0xa9059cbb")
      expect(interface.function("getPosition").ruby_name).to eq(:get_position)
      expect(interface.function("safeMint(address,bytes)").inputs.size).to eq(2)
    end

    it "resolves overloads by arity or keyword names" do
      expect(interface.function(:safe_mint, args: [OTHER_ADDRESS]).inputs.size).to eq(1)
      expect(interface.function(:safe_mint, kwargs: { to: 1, data: 2 }).inputs.size).to eq(2)
      expect { interface.function(:safe_mint) }.to raise_error(BlockGiven::FunctionNotFoundError, /overload/)
      expect { interface.function(:nope) }.to raise_error(BlockGiven::FunctionNotFoundError, /known:/)
    end
  end

  describe "functions" do
    it "encodes positional and keyword arguments" do
      fn = interface.function(:transfer)
      expected = "0xa9059cbb#{BlockGiven::Utils.strip_hex(abi_encode(%w[address uint256], [OTHER_ADDRESS, 1_000_000]))}"
      expect(fn.encode([OTHER_ADDRESS, 1_000_000])).to eq(expected)
      expect(fn.encode([], { to: OTHER_ADDRESS, amount: 1e6 })).to eq(expected)
      expect(fn.encode([], { "amount" => "1000000", "_to" => OTHER_ADDRESS })).to eq(expected)
    end

    it "explains bad keyword arguments" do
      fn = interface.function(:transfer)
      expect { fn.encode([], { to: OTHER_ADDRESS, value: 1 }) }
        .to raise_error(BlockGiven::InvalidArgumentError, /unknown argument\(s\) value \(expected to, amount\)/)
      expect { fn.encode([], { to: OTHER_ADDRESS }) }.to raise_error(BlockGiven::InvalidArgumentError, /missing argument\(s\) amount/)
      expect { fn.encode([OTHER_ADDRESS], { amount: 1 }) }.to raise_error(BlockGiven::InvalidArgumentError, /mix/)
    end

    it "rejects fractional numbers, bad addresses and overflows" do
      fn = interface.function(:transfer)
      expect { fn.encode([OTHER_ADDRESS, 1.5]) }.to raise_error(BlockGiven::InvalidArgumentError, /parse_units/)
      expect { fn.encode(["0x12", 1]) }.to raise_error(BlockGiven::InvalidAddressError)
      expect { fn.encode([OTHER_ADDRESS, 2**256]) }.to raise_error(BlockGiven::AbiError)
    end

    it "accepts wallets as addresses" do
      wallet = BlockGiven::Wallet.new(private_key: TEST_PRIVATE_KEY)
      expect(interface.function(:transfer).encode([wallet, 1])).to include(BlockGiven::Utils.strip_hex(TEST_ADDRESS).downcase)
    end

    it "encodes tuple arrays from hashes or arrays" do
      fn = interface.function(:batch)
      from_hash = fn.encode([[{ token_id: 1, price: 2 }, { "tokenId" => 3, "price" => 4 }]])
      from_array = fn.encode([[[1, 2], [3, 4]]])
      expect(from_hash).to eq(from_array)
      expect(fn.signature).to eq("batch((uint256,uint256)[])")
      expect(fn.payable?).to be true
    end

    it "decodes single, multiple and tuple outputs" do
      expect(interface.function(:transfer).decode_output(word(1))).to be true
      expect(interface.function(:batch).decode_output(abi_encode(%w[uint256 bool], [7, false]))).to eq([7, false])

      encoded = abi_encode(["(address,uint128,string[])"], [[OTHER_ADDRESS.downcase, 42, %w[a b]]])
      expect(interface.function(:get_position).decode_output(encoded))
        .to eq(owner: OTHER_ADDRESS, shares: 42, tags: %w[a b])
    end

    it "raises a clear error on empty return data" do
      expect { interface.function(:transfer).decode_output("0x") }.to raise_error(BlockGiven::AbiError, /empty data/)
    end
  end

  describe "events" do
    let(:transfer) { interface.event(:transfer) }

    it "computes the topic" do
      expect(transfer.topic).to eq("0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef")
    end

    it "decodes logs" do
      log = { address: USDC_BASE.downcase, block_number: 5, log_index: 0,
              topics: [transfer.topic, word(TEST_ADDRESS), word(OTHER_ADDRESS)], data: word(1_000_000) }
      event = transfer.decode(log)
      expect(event.name).to eq("Transfer")
      expect(event.args).to eq(from: TEST_ADDRESS, to: OTHER_ADDRESS, value: 1_000_000)
      expect(event[:value]).to eq(1_000_000)
      expect(event["to"]).to eq(OTHER_ADDRESS)
      expect(event.address).to eq(USDC_BASE)
      expect(event.block_number).to eq(5)
    end

    it "keeps the hash for indexed dynamic types" do
      named = interface.event(:named)
      log = { topics: [named.topic, BlockGiven::Utils.keccak256("hello")], data: abi_encode(%w[uint256 address], [1, OTHER_ADDRESS]) }
      expect(named.decode(log).args).to eq(label: BlockGiven::Utils.keccak256("hello"), id: 1, who: OTHER_ADDRESS)
    end

    it "encodes topic filters with wildcards and OR lists" do
      expect(transfer.encode_topics).to eq([transfer.topic])
      expect(transfer.encode_topics(to: OTHER_ADDRESS)).to eq([transfer.topic, nil, word(OTHER_ADDRESS).downcase])
      expect(transfer.encode_topics(from: [TEST_ADDRESS, OTHER_ADDRESS]))
        .to eq([transfer.topic, [word(TEST_ADDRESS).downcase, word(OTHER_ADDRESS).downcase]])
      expect(interface.event(:named).encode_topics(label: "hello")).to eq([interface.event(:named).topic, BlockGiven::Utils.keccak256("hello")])
      expect { transfer.encode_topics(value: 1) }.to raise_error(BlockGiven::InvalidArgumentError, /not an indexed/)
    end
  end

  describe "custom errors" do
    it "decodes custom error data" do
      error = interface.errors.first
      data = error.selector + BlockGiven::Utils.strip_hex(abi_encode(["address"], [OTHER_ADDRESS]))
      expect(error.decode(data)).to eq(caller: OTHER_ADDRESS)
    end
  end
end
