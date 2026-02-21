require "../../spec_helper"

# Minimal testable subclass that stubs HTTP calls for streaming tests.
class StreamingTestableHttpProvider < Autobot::Providers::HttpProvider
  getter last_api_model : String?

  private def http_post(url : String, headers : HTTP::Headers, body : String) : HTTP::Client::Response
    parsed = JSON.parse(body)
    @last_api_model = parsed["model"]?.try(&.as_s?)
    if url.includes?("/messages")
      HTTP::Client::Response.new(200, body: %({"type":"message","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":0,"output_tokens":0}}))
    else
      HTTP::Client::Response.new(200, body: %({"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}}))
    end
  end

  def test_parse_compatible_sse(io : IO, &on_delta : Autobot::Providers::StreamCallback) : Autobot::Providers::Response
    parse_compatible_sse(io, &on_delta)
  end

  def test_parse_anthropic_sse(io : IO, &on_delta : Autobot::Providers::StreamCallback) : Autobot::Providers::Response
    parse_anthropic_sse(io, &on_delta)
  end
end

# Minimal concrete provider that uses the base class chat_streaming fallback.
# Defined inside the module to access abstract method default constants.
module Autobot::Providers
  class FallbackTestProvider < Provider
    @next_content : String? = nil

    def initialize
      super("test-key")
    end

    def default_model : String
      "test-model"
    end

    def chat(
      messages : Array(Hash(String, JSON::Any)),
      tools : Array(Hash(String, JSON::Any))? = nil,
      model : String? = nil,
      max_tokens : Int32 = DEFAULT_MAX_TOKENS,
      temperature : Float64 = DEFAULT_TEMPERATURE,
    ) : Response
      Response.new(content: @next_content, finish_reason: "stop")
    end

    def next_content=(@next_content : String?)
    end
  end
end

describe "Provider#chat_streaming fallback" do
  it "calls chat and yields the full content at once" do
    provider = Autobot::Providers::FallbackTestProvider.new
    provider.next_content=("Hello from fallback")
    messages = [{"role" => JSON::Any.new("user"), "content" => JSON::Any.new("hi")}]

    deltas = [] of String
    response = provider.chat_streaming(messages) { |delta| deltas << delta }

    response.content.should eq("Hello from fallback")
    response.finish_reason.should eq("stop")
    deltas.should eq(["Hello from fallback"])
  end

  it "does not yield when content is nil" do
    provider = Autobot::Providers::FallbackTestProvider.new
    provider.next_content=(nil)
    messages = [{"role" => JSON::Any.new("user"), "content" => JSON::Any.new("hi")}]

    deltas = [] of String
    response = provider.chat_streaming(messages) { |delta| deltas << delta }

    response.content.should be_nil
    deltas.should be_empty
  end
end

describe "HttpProvider#parse_compatible_sse" do
  provider = StreamingTestableHttpProvider.new(api_key: "test-key")

  describe "simple text streaming" do
    it "accumulates content from multiple delta chunks" do
      sse = <<-SSE
      data: {"choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

      data: {"choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}

      data: {"choices":[{"index":0,"delta":{"content":" world"},"finish_reason":null}]}

      data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}

      data: [DONE]
      SSE

      deltas = [] of String
      response = provider.test_parse_compatible_sse(IO::Memory.new(sse)) { |delta| deltas << delta }

      response.content.should eq("Hello world")
      response.finish_reason.should eq("stop")
      response.tool_calls.should be_empty
      response.usage.prompt_tokens.should eq(10)
      response.usage.completion_tokens.should eq(5)
      response.usage.total_tokens.should eq(15)

      deltas.should eq(["", "Hello", " world"])
    end
  end

  describe "streaming with tool calls" do
    it "accumulates fragmented tool call deltas" do
      sse = <<-SSE
      data: {"choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_123","type":"function","function":{"name":"read_file","arguments":""}}]},"finish_reason":null}]}

      data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"path\\":"}}]},"finish_reason":null}]}

      data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"/tmp/test\\"}"}}]},"finish_reason":null}]}

      data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

      data: [DONE]
      SSE

      deltas = [] of String
      response = provider.test_parse_compatible_sse(IO::Memory.new(sse)) { |delta| deltas << delta }

      response.content.should be_nil
      response.finish_reason.should eq("tool_calls")
      response.has_tool_calls?.should be_true
      response.tool_calls.size.should eq(1)
      response.tool_calls[0].id.should eq("call_123")
      response.tool_calls[0].name.should eq("read_file")
      response.tool_calls[0].arguments["path"].as_s.should eq("/tmp/test")

      deltas.should be_empty
    end
  end

  describe "mixed content and tool calls" do
    it "captures both text and tool calls" do
      sse = <<-SSE
      data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"Let me "},"finish_reason":null}]}

      data: {"choices":[{"index":0,"delta":{"content":"check."},"finish_reason":null}]}

      data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_456","type":"function","function":{"name":"list_dir","arguments":""}}]},"finish_reason":null}]}

      data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"path\\":\\"/tmp\\"}"}}]},"finish_reason":null}]}

      data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

      data: [DONE]
      SSE

      deltas = [] of String
      response = provider.test_parse_compatible_sse(IO::Memory.new(sse)) { |delta| deltas << delta }

      response.content.should eq("Let me check.")
      response.finish_reason.should eq("tool_calls")
      response.tool_calls.size.should eq(1)
      response.tool_calls[0].name.should eq("list_dir")

      deltas.should eq(["Let me ", "check."])
    end
  end

  describe "empty response" do
    it "returns nil content for DONE-only stream" do
      sse = <<-SSE
      data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

      data: [DONE]
      SSE

      deltas = [] of String
      response = provider.test_parse_compatible_sse(IO::Memory.new(sse)) { |delta| deltas << delta }

      response.content.should be_nil
      response.finish_reason.should eq("stop")
      response.tool_calls.should be_empty
      deltas.should be_empty
    end
  end

  describe "error in SSE data" do
    it "raises on malformed JSON in data line" do
      sse = <<-SSE
      data: not valid json

      data: [DONE]
      SSE

      expect_raises(JSON::ParseException) do
        provider.test_parse_compatible_sse(IO::Memory.new(sse)) { |_delta| }
      end
    end
  end

  describe "null JSON fields" do
    it "handles null delta in choice" do
      sse = <<-SSE
      data: {"choices":[{"index":0,"delta":null,"finish_reason":null}]}

      data: {"choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}

      data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

      data: [DONE]
      SSE

      deltas = [] of String
      response = provider.test_parse_compatible_sse(IO::Memory.new(sse)) { |delta| deltas << delta }

      response.content.should eq("Hi")
      deltas.should eq(["Hi"])
    end

    it "handles null usage" do
      sse = <<-SSE
      data: {"choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}

      data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":null}

      data: [DONE]
      SSE

      deltas = [] of String
      response = provider.test_parse_compatible_sse(IO::Memory.new(sse)) { |delta| deltas << delta }

      response.content.should eq("Hi")
      response.usage.prompt_tokens.should eq(0)
    end

    it "handles null function in tool call fragment" do
      sse = <<-SSE
      data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"test","arguments":""}}]},"finish_reason":null}]}

      data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":null}]},"finish_reason":null}]}

      data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

      data: [DONE]
      SSE

      deltas = [] of String
      response = provider.test_parse_compatible_sse(IO::Memory.new(sse)) { |delta| deltas << delta }

      response.finish_reason.should eq("tool_calls")
      response.tool_calls.size.should eq(1)
      response.tool_calls[0].name.should eq("test")
    end
  end

  describe "usage without finish in final chunk" do
    it "captures usage from the last chunk" do
      sse = <<-SSE
      data: {"choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}

      data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":1,"total_tokens":4}}

      data: [DONE]
      SSE

      deltas = [] of String
      response = provider.test_parse_compatible_sse(IO::Memory.new(sse)) { |delta| deltas << delta }

      response.usage.prompt_tokens.should eq(3)
      response.usage.completion_tokens.should eq(1)
      response.usage.total_tokens.should eq(4)
    end
  end
end

describe "HttpProvider#parse_anthropic_sse" do
  provider = StreamingTestableHttpProvider.new(api_key: "test-key")

  describe "simple text streaming" do
    it "accumulates text from content_block_delta events" do
      sse = <<-SSE
      data: {"type":"message_start","message":{"usage":{"input_tokens":25}}}

      data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}

      data: {"type":"content_block_stop","index":0}

      data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":10}}

      data: {"type":"message_stop"}
      SSE

      deltas = [] of String
      response = provider.test_parse_anthropic_sse(IO::Memory.new(sse)) { |delta| deltas << delta }

      response.content.should eq("Hello world")
      response.finish_reason.should eq("stop")
      response.tool_calls.should be_empty

      deltas.should eq(["Hello", " world"])
    end
  end

  describe "tool use streaming" do
    it "accumulates tool call from content_block_start and input_json_delta" do
      sse = <<-SSE
      data: {"type":"message_start","message":{"usage":{"input_tokens":25}}}

      data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool_1","name":"read_file"}}

      data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\":"}}

      data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\\"/tmp/test\\"}"}}

      data: {"type":"content_block_stop","index":0}

      data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":15}}
      SSE

      deltas = [] of String
      response = provider.test_parse_anthropic_sse(IO::Memory.new(sse)) { |delta| deltas << delta }

      response.content.should be_nil
      response.finish_reason.should eq("tool_calls")
      response.has_tool_calls?.should be_true
      response.tool_calls.size.should eq(1)
      response.tool_calls[0].id.should eq("tool_1")
      response.tool_calls[0].name.should eq("read_file")
      response.tool_calls[0].arguments["path"].as_s.should eq("/tmp/test")

      deltas.should be_empty
    end
  end

  describe "error event handling" do
    it "records error and sets finish_reason to error" do
      sse = <<-SSE
      data: {"type":"message_start","message":{"usage":{"input_tokens":5}}}

      data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
      SSE

      deltas = [] of String
      response = provider.test_parse_anthropic_sse(IO::Memory.new(sse)) { |delta| deltas << delta }

      response.finish_reason.should eq("error")
      response.error?.should be_true
      response.content.should eq("Streaming error: Overloaded")
    end
  end

  describe "mixed text and tool_use blocks" do
    it "captures text content and tool calls from separate blocks" do
      sse = <<-SSE
      data: {"type":"message_start","message":{"usage":{"input_tokens":25}}}

      data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Let me check."}}

      data: {"type":"content_block_stop","index":0}

      data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tool_1","name":"read_file"}}

      data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\":"}}

      data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"/tmp/test\\"}"}}

      data: {"type":"content_block_stop","index":1}

      data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":15}}
      SSE

      deltas = [] of String
      response = provider.test_parse_anthropic_sse(IO::Memory.new(sse)) { |delta| deltas << delta }

      response.content.should eq("Let me check.")
      response.finish_reason.should eq("tool_calls")
      response.has_tool_calls?.should be_true
      response.tool_calls.size.should eq(1)
      response.tool_calls[0].id.should eq("tool_1")
      response.tool_calls[0].name.should eq("read_file")
      response.tool_calls[0].arguments["path"].as_s.should eq("/tmp/test")

      deltas.should eq(["Let me check."])
    end
  end

  describe "usage tracking" do
    it "tracks input tokens from message_start and output tokens from message_delta" do
      sse = <<-SSE
      data: {"type":"message_start","message":{"usage":{"input_tokens":42}}}

      data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}

      data: {"type":"content_block_stop","index":0}

      data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}

      data: {"type":"message_stop"}
      SSE

      deltas = [] of String
      response = provider.test_parse_anthropic_sse(IO::Memory.new(sse)) { |delta| deltas << delta }

      response.usage.prompt_tokens.should eq(42)
      response.usage.completion_tokens.should eq(7)
      response.usage.total_tokens.should eq(49)
    end

    it "defaults to zero usage when no usage events are present" do
      sse = <<-SSE
      data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}

      data: {"type":"content_block_stop","index":0}

      data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

      data: {"type":"message_stop"}
      SSE

      deltas = [] of String
      response = provider.test_parse_anthropic_sse(IO::Memory.new(sse)) { |delta| deltas << delta }

      response.usage.prompt_tokens.should eq(0)
      response.usage.completion_tokens.should eq(0)
      response.usage.total_tokens.should eq(0)
    end
  end

  describe "empty content blocks" do
    it "returns nil content when text block has no deltas" do
      sse = <<-SSE
      data: {"type":"message_start","message":{"usage":{"input_tokens":5}}}

      data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

      data: {"type":"content_block_stop","index":0}

      data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":0}}

      data: {"type":"message_stop"}
      SSE

      deltas = [] of String
      response = provider.test_parse_anthropic_sse(IO::Memory.new(sse)) { |delta| deltas << delta }

      response.content.should be_nil
      response.finish_reason.should eq("stop")
      deltas.should be_empty
    end
  end

  describe "null JSON fields" do
    it "handles null message in message_start" do
      sse = <<-SSE
      data: {"type":"message_start","message":null}

      data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}

      data: {"type":"content_block_stop","index":0}

      data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

      data: {"type":"message_stop"}
      SSE

      deltas = [] of String
      response = provider.test_parse_anthropic_sse(IO::Memory.new(sse)) { |delta| deltas << delta }

      response.content.should eq("Hi")
      response.usage.prompt_tokens.should eq(0)
      deltas.should eq(["Hi"])
    end

    it "handles null content_block in content_block_start" do
      sse = <<-SSE
      data: {"type":"message_start","message":{"usage":{"input_tokens":5}}}

      data: {"type":"content_block_start","index":0,"content_block":null}

      data: {"type":"content_block_stop","index":0}

      data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":0}}

      data: {"type":"message_stop"}
      SSE

      deltas = [] of String
      response = provider.test_parse_anthropic_sse(IO::Memory.new(sse)) { |delta| deltas << delta }

      response.content.should be_nil
      deltas.should be_empty
    end

    it "handles null delta in content_block_delta" do
      sse = <<-SSE
      data: {"type":"message_start","message":{"usage":{"input_tokens":5}}}

      data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

      data: {"type":"content_block_delta","index":0,"delta":null}

      data: {"type":"content_block_stop","index":0}

      data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":0}}

      data: {"type":"message_stop"}
      SSE

      deltas = [] of String
      response = provider.test_parse_anthropic_sse(IO::Memory.new(sse)) { |delta| deltas << delta }

      response.content.should be_nil
      deltas.should be_empty
    end

    it "handles null delta and usage in message_delta" do
      sse = <<-SSE
      data: {"type":"message_start","message":{"usage":{"input_tokens":5}}}

      data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}

      data: {"type":"content_block_stop","index":0}

      data: {"type":"message_delta","delta":null,"usage":null}

      data: {"type":"message_stop"}
      SSE

      deltas = [] of String
      response = provider.test_parse_anthropic_sse(IO::Memory.new(sse)) { |delta| deltas << delta }

      response.content.should eq("Hi")
      response.usage.prompt_tokens.should eq(5)
      response.usage.completion_tokens.should eq(0)
    end

    it "handles null error in error event" do
      sse = <<-SSE
      data: {"type":"message_start","message":{"usage":{"input_tokens":5}}}

      data: {"type":"error","error":null}
      SSE

      deltas = [] of String
      response = provider.test_parse_anthropic_sse(IO::Memory.new(sse)) { |delta| deltas << delta }

      response.finish_reason.should eq("error")
      content = response.content
      content.should_not be_nil
      content.as(String).should contain("Unknown streaming error")
    end
  end

  describe "multiple tool_use blocks" do
    it "accumulates multiple tool calls" do
      sse = <<-SSE
      data: {"type":"message_start","message":{"usage":{"input_tokens":30}}}

      data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool_1","name":"read_file"}}

      data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\":\\"a.txt\\"}"}}

      data: {"type":"content_block_stop","index":0}

      data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tool_2","name":"write_file"}}

      data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\":\\"b.txt\\",\\"content\\":\\"hi\\"}"}}

      data: {"type":"content_block_stop","index":1}

      data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}
      SSE

      deltas = [] of String
      response = provider.test_parse_anthropic_sse(IO::Memory.new(sse)) { |delta| deltas << delta }

      response.finish_reason.should eq("tool_calls")
      response.tool_calls.size.should eq(2)
      response.tool_calls[0].id.should eq("tool_1")
      response.tool_calls[0].name.should eq("read_file")
      response.tool_calls[0].arguments["path"].as_s.should eq("a.txt")
      response.tool_calls[1].id.should eq("tool_2")
      response.tool_calls[1].name.should eq("write_file")
      response.tool_calls[1].arguments["path"].as_s.should eq("b.txt")
      response.tool_calls[1].arguments["content"].as_s.should eq("hi")
    end
  end
end
