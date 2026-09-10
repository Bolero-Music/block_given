# frozen_string_literal: true

RSpec.describe Vium::Connectors::Http do
  let(:url) { "https://mainnet.infura.io/v3/infura-secret-key" }
  subject(:connector) { described_class.new(url: url, retries: 0) }

  it "falls back to the chain's public RPC when no url is given" do
    expect(described_class.new.endpoint(Vium::Chains::BASE)).to eq("https://mainnet.base.org")
    expect { described_class.new.endpoint(Vium::Chain.new(id: 1, name: "x")) }.to raise_error(Vium::ConfigurationError)
    expect(described_class.new.inspect).to eq("#<Vium::Connectors::Http url=chain default>")
  end

  it "keeps only scheme and host of the url in inspect and errors" do
    expect(connector.inspect).to eq('#<Vium::Connectors::Http url="https://mainnet.infura.io/…">')
    expect(connector.redact("http://127.0.0.1:8545")).to eq("http://127.0.0.1:8545")
    expect(connector.redact("https://rpc.example.com/")).to eq("https://rpc.example.com")
    expect(connector.redact("not a url at all ://")).to eq("<invalid url>")

    stub_request(:post, url).to_return(status: 401, body: "invalid project id")
    expect { connector.request("eth_chainId", [], chain: Vium::Chains::MAINNET) }.to raise_error(Vium::HttpError) do |e|
      expect(e.message).to eq("HTTP 401 from https://mainnet.infura.io/…: invalid project id")
      expect(e.message).not_to include("infura-secret-key")
    end
  end

  it "raises HttpError on connection failures and invalid JSON" do
    stub_request(:post, url).to_raise(Errno::ECONNREFUSED)
    expect { connector.request("eth_chainId", [], chain: nil) }.to raise_error(Vium::HttpError, /ECONNREFUSED/)

    stub_request(:post, url).to_return(body: "<html>")
    expect { connector.request("eth_chainId", [], chain: nil) }.to raise_error(Vium::HttpError, /invalid JSON/)
  end
end
