# frozen_string_literal: true

RSpec.describe BlockGiven::Abis do
  let(:interfaces) { described_class.names.to_h { |name| [name, BlockGiven::Abi::Interface.parse(described_class.fetch(name))] } }

  it "ships the four token standards" do
    expect(described_class.names).to eq(%i[erc20 erc721 erc1155 erc4626])
    expect(described_class::ERC20).to be_a(Array)
  end

  it "uses the JSON ABI shape everywhere (string keys, stateMutability, outputs)" do
    described_class.names.each do |name|
      described_class.fetch(name).each do |definition|
        expect(definition.keys).to all(be_a(String))
        expect(definition).to include("type", "name", "inputs")
        expect(definition).to include("stateMutability", "outputs") if definition["type"] == "function"
        expect(definition).to include("anonymous") if definition["type"] == "event"
      end
    end
  end

  it "is deeply frozen" do
    abi = described_class::ERC20
    transfer = abi.find { |d| d["name"] == "transfer" }
    expect(abi).to be_frozen
    expect(abi).to all(be_frozen)
    expect(transfer["inputs"]).to be_frozen
    expect(transfer["inputs"].first).to be_frozen
    expect(transfer["inputs"].first["name"]).to be_frozen
  end

  describe ".fetch" do
    it "accepts symbols, strings, any case and an EIP dash" do
      expect(described_class.fetch(:erc20)).to equal(described_class::ERC20)
      expect(described_class.fetch("ERC721")).to equal(described_class::ERC721)
      expect(described_class.fetch("erc-1155")).to equal(described_class::ERC1155)
      expect(described_class.fetch("ERC-4626")).to equal(described_class::ERC4626)
    end

    it "raises AbiError listing the shipped names" do
      expect { described_class.fetch(:erc777) }.to raise_error(BlockGiven::AbiError, /erc777.*erc20/)
    end
  end

  describe "ERC20" do
    let(:erc20) { interfaces[:erc20] }

    it "has the EIP-20 selectors and events" do
      expect(erc20.function(:transfer).selector).to eq("0xa9059cbb")
      expect(erc20.function(:transfer_from).selector).to eq("0x23b872dd")
      expect(erc20.function(:approve).selector).to eq("0x095ea7b3")
      expect(erc20.function(:balance_of).selector).to eq("0x70a08231")
      expect(erc20.function(:allowance).selector).to eq("0xdd62ed3e")
      expect(erc20.function(:total_supply).selector).to eq("0x18160ddd")
      expect(erc20.functions.map(&:name)).to include("name", "symbol", "decimals")
      expect(erc20.event(:Transfer).topic).to eq("0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef")
      expect(erc20.event(:Approval).topic).to eq("0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925")
    end

    it "names inputs the way the README documents them" do
      expect(erc20.function(:transfer).input_names).to eq(%i[to amount])
      expect(erc20.function(:transfer_from).input_names).to eq(%i[from to amount])
      expect(erc20.function(:balance_of).input_names).to eq(%i[account])
      expect(erc20.function(:approve).input_names).to eq(%i[spender amount])
    end

    it "decodes the ERC-6093 custom errors" do
      expect(erc20.errors.map(&:name)).to contain_exactly(
        "ERC20InsufficientBalance", "ERC20InvalidSender", "ERC20InvalidReceiver",
        "ERC20InsufficientAllowance", "ERC20InvalidApprover", "ERC20InvalidSpender"
      )
      expect(erc20.errors.find { |e| e.name == "ERC20InsufficientBalance" }.selector).to eq("0xe450d38c")
    end
  end

  describe "ERC721" do
    let(:erc721) { interfaces[:erc721] }

    it "has the EIP-721 selectors, both safeTransferFrom overloads and ERC-165" do
      expect(erc721.function(:owner_of).selector).to eq("0x6352211e")
      expect(erc721.function(:safe_transfer_from, args: [1, 2, 3]).selector).to eq("0x42842e0e")
      expect(erc721.function(:safe_transfer_from, args: [1, 2, 3, 4]).selector).to eq("0xb88d4fde")
      expect(erc721.function("safeTransferFrom(address,address,uint256,bytes)").input_names).to eq(%i[from to token_id data])
      expect(erc721.function(:set_approval_for_all).selector).to eq("0xa22cb465")
      expect(erc721.function(:supports_interface).selector).to eq("0x01ffc9a7")
      expect(erc721.event(:Transfer).topic).to eq("0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef")
      expect(erc721.event(:Transfer).indexed_inputs.map(&:ruby_name)).to eq(%i[from to token_id])
    end

    it "includes metadata and enumerable extensions" do
      expect(erc721.function(:token_uri).selector).to eq("0xc87b56dd")
      expect(erc721.function(:token_of_owner_by_index).selector).to eq("0x2f745c59")
      expect(erc721.function(:token_by_index).selector).to eq("0x4f6ccce7")
    end

    it "decodes the ERC-6093 custom errors" do
      expect(erc721.errors.map(&:name)).to include("ERC721NonexistentToken", "ERC721IncorrectOwner", "ERC721OutOfBoundsIndex")
    end
  end

  describe "ERC1155" do
    let(:erc1155) { interfaces[:erc1155] }

    it "has the EIP-1155 selectors, batch calls and ERC-165" do
      expect(erc1155.function(:balance_of).selector).to eq("0x00fdd58e")
      expect(erc1155.function(:balance_of_batch).selector).to eq("0x4e1273f4")
      expect(erc1155.function(:safe_transfer_from).selector).to eq("0xf242432a")
      expect(erc1155.function(:safe_batch_transfer_from).selector).to eq("0x2eb2c2d6")
      expect(erc1155.function(:uri).selector).to eq("0x0e89341c")
      expect(erc1155.function(:supports_interface).selector).to eq("0x01ffc9a7")
      expect(erc1155.event(:TransferSingle).topic).to eq("0xc3d58168c5ae7397731d063d5bbf3d657854427343f4c083240f7aacaa2d0f62")
      expect(erc1155.event(:TransferBatch).topic).to eq("0x4a39dc06d4c0dbc64b70af90fd698a233a518aa5d07e595d983b8c0526c8f7fb")
      expect(erc1155.event(:URI).indexed_inputs.map(&:ruby_name)).to eq(%i[id])
    end

    it "decodes the ERC-6093 custom errors" do
      expect(erc1155.errors.map(&:name)).to include("ERC1155InsufficientBalance", "ERC1155MissingApprovalForAll")
    end
  end

  describe "ERC4626" do
    let(:erc4626) { interfaces[:erc4626] }

    it "extends ERC20 with the vault functions and events" do
      expect(erc4626.function(:transfer).selector).to eq("0xa9059cbb")
      expect(erc4626.function(:asset).selector).to eq("0x38d52e0f")
      expect(erc4626.function(:deposit).selector).to eq("0x6e553f65")
      expect(erc4626.function(:redeem).selector).to eq("0xba087652")
      expect(erc4626.function(:convert_to_shares).selector).to eq("0xc6e6f592")
      expect(erc4626.event(:Deposit).topic).to eq("0xdcbc1c05240f31ff3ad067ef1ee35ce4997762752e3a095284754544f4c709d7")
      expect(erc4626.event(:Withdraw).topic).to eq("0xfbde797d201c681b91056529119e0b02407c7bb96a4a2c75c01fc9667232c8db")
    end
  end

  describe "in a contract" do
    let(:stub) { build_stub("eth_call" => word(12_500_000)) }

    before { configure_block_given(stub) }

    it "loads through Contract.abi with the constant or the name" do
      by_constant = Class.new(BlockGiven::Contract) { abi BlockGiven::Abis::ERC20 }
      by_name = Class.new(BlockGiven::Contract) { abi :erc20 }
      expect(by_constant.functions.map(&:signature)).to eq(by_name.functions.map(&:signature))
      expect(by_name.at(USDC_BASE).balance_of(TEST_ADDRESS)).to eq(12_500_000)
      expect(stub.calls_for("eth_call").first.first[:data]).to start_with("0x70a08231")
    end

    it "keeps the README keywords working" do
      usdc = Class.new(BlockGiven::Contract) { abi :erc20 }.at(USDC_BASE, wallet: BlockGiven::Wallet.new(private_key: TEST_PRIVATE_KEY))
      expect(usdc.encode_function_data(:transfer, to: OTHER_ADDRESS, amount: 1e6)).to start_with("0xa9059cbb")
      expect { usdc.encode_function_data(:transfer, recipient: OTHER_ADDRESS, amount: 1) }
        .to raise_error(BlockGiven::InvalidArgumentError, /expected to, amount/)
    end
  end
end
