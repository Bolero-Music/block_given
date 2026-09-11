# frozen_string_literal: true

RSpec.describe UncleBlockGiven::Utils do
  describe ".parse_units / .format_units" do
    it "scales decimal strings" do
      expect(described_class.parse_units("1.5", 6)).to eq(1_500_000)
      expect(described_class.parse_units("0.000001", 6)).to eq(1)
      expect(described_class.parse_units(12, 18)).to eq(12 * 10**18)
      expect(described_class.parse_units(1.25, 2)).to eq(125)
    end

    it "rejects values with too many decimals" do
      expect { described_class.parse_units("1.0000001", 6) }.to raise_error(UncleBlockGiven::InvalidArgumentError)
    end

    it "formats without trailing zeros" do
      expect(described_class.format_units(1_500_000, 6)).to eq("1.5")
      expect(described_class.format_units(10**18, 18)).to eq("1")
      expect(described_class.format_units(123, 6)).to eq("0.000123")
      expect(described_class.format_units(0, 6)).to eq("0")
    end

    it "has ether / gwei shortcuts" do
      expect(described_class.parse_ether("1")).to eq(10**18)
      expect(described_class.parse_gwei("2")).to eq(2_000_000_000)
      expect(described_class.format_ether(15 * 10**17)).to eq("1.5")
    end
  end

  describe "hex helpers" do
    it "converts quantities" do
      expect(described_class.to_hex(26)).to eq("0x1a")
      expect(described_class.hex_to_int("0x1a")).to eq(26)
      expect(described_class.hex_to_int(nil)).to be_nil
      expect(described_class.hex?("0xAb01")).to be true
      expect(described_class.hex?("0xzz")).to be false
    end

    it "builds block tags" do
      expect(described_class.block_tag(nil)).to eq("latest")
      expect(described_class.block_tag(:pending)).to eq("pending")
      expect(described_class.block_tag(255)).to eq("0xff")
      expect { described_class.block_tag("yesterday") }.to raise_error(UncleBlockGiven::InvalidArgumentError)
    end
  end

  describe ".keccak256" do
    it "hashes raw strings and hex bytes" do
      expect(described_class.keccak256("transfer(address,uint256)")).to start_with("0xa9059cbb")
      expect(described_class.keccak256("0x")).to eq("0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
    end
  end

  describe ".checksum_address" do
    it "checksums and validates" do
      expect(described_class.checksum_address(TEST_ADDRESS.downcase)).to eq(TEST_ADDRESS)
      expect { described_class.checksum_address("0x123") }.to raise_error(UncleBlockGiven::InvalidAddressError)
    end

    it "accepts objects responding to #address" do
      wallet = UncleBlockGiven::Wallet.new(private_key: TEST_PRIVATE_KEY)
      expect(described_class.checksum_address(wallet)).to eq(TEST_ADDRESS)
    end
  end

  describe ".snake_case" do
    it "converts Solidity names" do
      expect(described_class.snake_case("balanceOf")).to eq("balance_of")
      expect(described_class.snake_case("_to")).to eq("to")
      expect(described_class.snake_case("DOMAIN_SEPARATOR")).to eq("domain_separator")
      expect(described_class.snake_case("getURI")).to eq("get_uri")
      expect(described_class.snake_case("ERC20InsufficientBalance")).to eq("erc20_insufficient_balance")
    end
  end
end
