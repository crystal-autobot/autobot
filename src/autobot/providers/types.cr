module Autobot
  module Providers
    # Token usage from an LLM API response.
    struct TokenUsage
      include JSON::Serializable

      getter prompt_tokens : Int32
      getter completion_tokens : Int32
      getter total_tokens : Int32

      def initialize(
        @prompt_tokens = 0,
        @completion_tokens = 0,
        @total_tokens = 0,
      )
      end

      def zero? : Bool
        total_tokens == 0
      end
    end

    # A tool/function call requested by the LLM.
    struct ToolCall
      include JSON::Serializable

      getter id : String
      getter name : String
      getter arguments : Hash(String, JSON::Any)
      getter extra_content : JSON::Any?

      def initialize(@id, @name, @arguments = {} of String => JSON::Any, @extra_content = nil)
      end
    end

    # Response from an LLM provider.
    class Response
      include JSON::Serializable

      getter content : String?
      getter tool_calls : Array(ToolCall)
      getter finish_reason : String
      getter usage : TokenUsage
      getter reasoning_content : String?

      def initialize(
        @content = nil,
        @tool_calls = [] of ToolCall,
        @finish_reason = "stop",
        @usage = TokenUsage.new,
        @reasoning_content = nil,
      )
      end

      def has_tool_calls? : Bool
        !tool_calls.empty?
      end

      def error? : Bool
        finish_reason == "error"
      end
    end
  end
end
