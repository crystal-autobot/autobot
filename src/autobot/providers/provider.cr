module Autobot
  module Providers
    # Default LLM parameters
    DEFAULT_MAX_TOKENS  = 4096
    DEFAULT_TEMPERATURE =  0.7

    # Abstract base for LLM providers.
    #
    # Implementations handle the specifics of each provider's API
    # while maintaining a consistent interface for the agent loop.
    abstract class Provider
      getter api_key : String
      getter api_base : String?

      def initialize(@api_key, @api_base = nil)
      end

      # Send a chat completion request.
      abstract def chat(
        messages : Array(Hash(String, JSON::Any)),
        tools : Array(Hash(String, JSON::Any))? = nil,
        model : String? = nil,
        max_tokens : Int32 = DEFAULT_MAX_TOKENS,
        temperature : Float64 = DEFAULT_TEMPERATURE,
      ) : Response

      # Send a streaming chat completion request.
      #
      # Yields text deltas to the block as they arrive. Returns the complete
      # response when finished. The default implementation falls back to
      # non-streaming `chat` and yields the full content at once.
      def chat_streaming(
        messages : Array(Hash(String, JSON::Any)),
        tools : Array(Hash(String, JSON::Any))? = nil,
        model : String? = nil,
        max_tokens : Int32 = DEFAULT_MAX_TOKENS,
        temperature : Float64 = DEFAULT_TEMPERATURE,
        &on_delta : StreamCallback
      ) : Response
        response = chat(messages, tools, model, max_tokens, temperature)
        if content = response.content
          on_delta.call(content)
        end
        response
      end

      # The default model identifier for this provider.
      abstract def default_model : String
    end
  end
end
