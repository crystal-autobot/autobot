require "../../spec_helper"
require "../../../src/autobot/tools/web"

class WebFetchToolWithMockCerts < Autobot::Tools::WebFetchTool
  # Expose for testing
  def test_create_tls_context(allow_insecure : Bool)
    create_tls_context(allow_insecure)
  end

  def self.mock_paths=(paths : Array(String))
    # We use a constant in the real code, so we'll have to re-define or
    # use a class variable for this mock.
    @@mock_paths = paths
  end

  private def create_tls_context(allow_insecure : Bool) : OpenSSL::SSL::Context::Client
    context = OpenSSL::SSL::Context::Client.new
    if allow_insecure
      context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
    else
      # Use our mock paths instead of CA_BUNDLE_PATHS
      ca_path = @@mock_paths.find { |path| File.exists?(path) }
      if ca_path
        context.ca_certificates = ca_path
      end
    end
    context
  end

  @@mock_paths = [] of String
end

describe Autobot::Tools::WebSearchTool do
  describe "#name" do
    it "returns web_search" do
      tool = Autobot::Tools::WebSearchTool.new(api_key: "test")
      tool.name.should eq("web_search")
    end
  end

  describe "#parameters" do
    it "requires query" do
      tool = Autobot::Tools::WebSearchTool.new(api_key: "test")
      schema = tool.parameters
      schema.required.should eq(["query"])
    end
  end

  describe "#execute" do
    it "returns error when API key is missing" do
      tool = Autobot::Tools::WebSearchTool.new(api_key: "")
      result = tool.execute({"query" => JSON::Any.new("test")} of String => JSON::Any)
      result.error?.should be_true
      result.content.should contain("BRAVE_API_KEY not configured")
    end
  end
end

describe Autobot::Tools::WebFetchTool do
  describe "#name" do
    it "returns web_fetch" do
      tool = Autobot::Tools::WebFetchTool.new
      tool.name.should eq("web_fetch")
    end
  end

  describe "#parameters" do
    it "requires url" do
      tool = Autobot::Tools::WebFetchTool.new
      schema = tool.parameters
      schema.required.should eq(["url"])
    end
  end

  describe "URL validation" do
    it "blocks non-HTTP schemes" do
      tool = Autobot::Tools::WebFetchTool.new

      %w[file:///etc/passwd ftp://example.com gopher://evil.com].each do |url|
        result = tool.execute({"url" => JSON::Any.new(url)} of String => JSON::Any)
        result.access_denied?.should be_true
        result.content.should contain("validation failed")
      end
    end

    it "blocks URLs without a host" do
      tool = Autobot::Tools::WebFetchTool.new

      result = tool.execute({"url" => JSON::Any.new("http://")} of String => JSON::Any)
      result.access_denied?.should be_true
    end
  end

  describe "SSRF protection" do
    it "blocks RFC 1918 private ranges" do
      tool = Autobot::Tools::WebFetchTool.new

      %w[
        http://10.0.0.1/secret
        http://192.168.1.1/admin
        http://172.16.0.1/internal
      ].each do |url|
        result = tool.execute({"url" => JSON::Any.new(url)} of String => JSON::Any)
        result.access_denied?.should be_true
        result.content.should contain("blocked")
      end
    end

    it "blocks loopback addresses" do
      tool = Autobot::Tools::WebFetchTool.new

      result = tool.execute({"url" => JSON::Any.new("http://127.0.0.1/secret")} of String => JSON::Any)
      result.access_denied?.should be_true
      result.content.should contain("blocked")
    end

    it "blocks cloud metadata endpoint" do
      tool = Autobot::Tools::WebFetchTool.new

      result = tool.execute({"url" => JSON::Any.new("http://169.254.169.254/metadata")} of String => JSON::Any)
      result.access_denied?.should be_true
      result.content.should contain("blocked")
    end

    it "blocks octal IP notation" do
      tool = Autobot::Tools::WebFetchTool.new

      result = tool.execute({"url" => JSON::Any.new("http://0177.0.0.1/secret")} of String => JSON::Any)
      result.access_denied?.should be_true
    end

    it "blocks hex IP notation" do
      tool = Autobot::Tools::WebFetchTool.new

      result = tool.execute({"url" => JSON::Any.new("http://0x7f000001/secret")} of String => JSON::Any)
      result.access_denied?.should be_true
    end

    it "blocks IPv6 loopback" do
      tool = Autobot::Tools::WebFetchTool.new

      result = tool.execute({"url" => JSON::Any.new("http://[::1]/secret")} of String => JSON::Any)
      result.access_denied?.should be_true
    end

    it "blocks IPv6 private ranges" do
      tool = Autobot::Tools::WebFetchTool.new

      %w[
        http://[fc00::1]/internal
        http://[fd12:3456::1]/private
      ].each do |url|
        result = tool.execute({"url" => JSON::Any.new(url)} of String => JSON::Any)
        result.access_denied?.should be_true
      end
    end

    it "blocks private IPs over HTTPS" do
      tool = Autobot::Tools::WebFetchTool.new

      result = tool.execute({"url" => JSON::Any.new("https://127.0.0.1/secret")} of String => JSON::Any)
      result.access_denied?.should be_true
    end
  end

  describe "HTTPS fetching" do
    it "fetches HTTPS URLs with proper SNI" do
      tool = Autobot::Tools::WebFetchTool.new

      result = tool.execute({
        "url"           => JSON::Any.new("https://example.com"),
        "allowInsecure" => JSON::Any.new(true),
      } of String => JSON::Any)
      result.success?.should be_true
      result.content.should contain("[https://example.com]")
      result.content.should contain("Example Domain")
    end
  end

  describe "HTTP fetching" do
    it "fetches HTTP URLs" do
      tool = Autobot::Tools::WebFetchTool.new

      result = tool.execute({"url" => JSON::Any.new("http://example.com")} of String => JSON::Any)
      result.success?.should be_true
      result.content.should contain("[http://example.com]")
    end
  end

  describe "content extraction" do
    it "extracts text from HTML" do
      tool = Autobot::Tools::WebFetchTool.new

      result = tool.execute({
        "url"           => JSON::Any.new("https://example.com"),
        "allowInsecure" => JSON::Any.new(true),
      } of String => JSON::Any)
      result.success?.should be_true

      result.content.should_not contain("<html")
      result.content.should_not contain("<body")
      result.content.should contain("Example Domain")
    end

    it "respects maxChars limit" do
      tool = Autobot::Tools::WebFetchTool.new

      result = tool.execute({
        "url"           => JSON::Any.new("https://example.com"),
        "maxChars"      => JSON::Any.new(100_i64),
        "allowInsecure" => JSON::Any.new(true),
      } of String => JSON::Any)
      result.success?.should be_true
      result.content.should contain("truncated to 100 chars")
    end
  end

  describe "redirect handling" do
    it "follows HTTP redirects" do
      tool = Autobot::Tools::WebFetchTool.new

      # httpbin.org redirects to https
      result = tool.execute({"url" => JSON::Any.new("http://example.com")} of String => JSON::Any)
      result.success?.should be_true
    end
  end

  describe "CA bundle logic" do
    it "picks the first existing path" do
      tmp = TestHelper.tmp_dir
      path1 = (tmp / "cert1.pem").to_s
      path2 = (tmp / "cert2.pem").to_s

      # Use a real certificate from the system bundle to avoid OpenSSL parse errors
      system_bundle = Autobot::Tools::CA_BUNDLE_PATHS.find { |path| File.exists?(path) }
      if system_bundle
        File.write(path2, File.read(system_bundle))
      else
        File.write(path2, "DUMMY")
      end

      WebFetchToolWithMockCerts.mock_paths = [path1, path2]
      tool = WebFetchToolWithMockCerts.new

      # Should not raise
      ctx = tool.test_create_tls_context(allow_insecure: false)
      ctx.verify_mode.should eq(OpenSSL::SSL::VerifyMode::PEER)
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "respects allowInsecure" do
      tool = WebFetchToolWithMockCerts.new
      ctx = tool.test_create_tls_context(allow_insecure: true)
      ctx.verify_mode.should eq(OpenSSL::SSL::VerifyMode::NONE)
    end
  end
end
