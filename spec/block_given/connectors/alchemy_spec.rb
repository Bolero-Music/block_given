# frozen_string_literal: true

RSpec.describe BlockGiven::Connectors::Alchemy do
  subject(:connector) { described_class.new(api_key: "secret-key-1234", retries: 1, retry_delay: 0) }

  it "builds the endpoint from the chain" do
    expect(connector.endpoint(BlockGiven::Chains::BASE)).to eq("https://base-mainnet.g.alchemy.com/v2/secret-key-1234")
    expect(connector.endpoint(BlockGiven::Chains::SEPOLIA)).to eq("https://eth-sepolia.g.alchemy.com/v2/secret-key-1234")
  end

  it "refuses chains Alchemy does not serve" do
    expect { connector.endpoint(BlockGiven::Chains::LOCALHOST) }.to raise_error(BlockGiven::ConfigurationError)
    expect { connector.endpoint(nil) }.to raise_error(BlockGiven::ConfigurationError)
  end

  it "requires an api key" do
    expect { described_class.new(api_key: nil) }.to raise_error(BlockGiven::ConfigurationError)
  end

  it "never leaks the key in inspect" do
    expect(connector.inspect).not_to include("secret-key-1234")
  end

  it "redacts endpoints while keeping the network host" do
    expect(connector.redact(connector.endpoint(BlockGiven::Chains::BASE_SEPOLIA)))
      .to eq("https://base-sepolia.g.alchemy.com/v2/secr…")
  end

  describe "JSON-RPC over HTTP" do
    let(:url) { "https://base-mainnet.g.alchemy.com/v2/secret-key-1234" }

    it "posts a JSON-RPC request and returns the result" do
      stub_request(:post, url)
        .with { |req| JSON.parse(req.body).values_at("method", "params") == ["eth_blockNumber", []] }
        .to_return(body: { jsonrpc: "2.0", id: 1, result: "0x10" }.to_json)

      expect(connector.request("eth_blockNumber", [], chain: BlockGiven::Chains::BASE)).to eq("0x10")
    end

    it "raises RpcError on error payloads" do
      stub_request(:post, url).to_return(body: { jsonrpc: "2.0", id: 1,
                                                 error: { code: -32_000, message: "nonce too low" } }.to_json)
      expect { connector.request("eth_sendRawTransaction", ["0x"], chain: BlockGiven::Chains::BASE) }
        .to raise_error(BlockGiven::RpcError, "nonce too low") { |e| expect(e.code).to eq(-32_000) }
    end

    it "surfaces reverts with decoded reason" do
      data = "0x08c379a0#{BlockGiven::Utils.strip_hex(abi_encode(['string'], ['not owner']))}"
      stub_request(:post, url).to_return(body: { jsonrpc: "2.0", id: 1,
                                                 error: { code: 3, message: "execution reverted", data: data } }.to_json)
      expect { connector.request("eth_call", [{}], chain: BlockGiven::Chains::BASE) }
        .to raise_error(BlockGiven::ContractRevertError, "execution reverted: not owner") { |e| expect(e.reason).to eq("not owner") }
    end

    it "retries on 429 then succeeds" do
      stub_request(:post, url)
        .to_return({ status: 429, body: "rate limited" }, { body: { jsonrpc: "2.0", id: 2, result: "0x1" }.to_json })
      expect(connector.request("eth_chainId", [], chain: BlockGiven::Chains::BASE)).to eq("0x1")
    end

    it "raises HttpError after exhausting retries, naming the network but not the key" do
      stub_request(:post, url).to_return(status: 503, body: "down")
      expect { connector.request("eth_chainId", [], chain: BlockGiven::Chains::BASE) }.to raise_error(BlockGiven::HttpError) do |e|
        expect(e.status).to eq(503)
        expect(e.message).to include("HTTP 503 from https://base-mainnet.g.alchemy.com/v2/secr…")
        expect(e.message).not_to include("secret-key-1234")
      end
    end

    it "batches requests" do
      stub_request(:post, url).to_return(
        body: [{ jsonrpc: "2.0", id: 2, result: "0x2" }, { jsonrpc: "2.0", id: 1, result: "0x1" }].to_json
      )
      results = connector.batch([["eth_chainId"], ["eth_blockNumber"]], chain: BlockGiven::Chains::BASE)
      expect(results).to eq(%w[0x1 0x2])
    end
  end
end
