module Autobot
  module Providers
    # Metadata for a single LLM provider. Drives env setup, model prefixing,
    # gateway detection, and display — no if-elif chains needed in provider code.
    struct ProviderSpec
      # Identity
      getter name : String
      getter keywords : Array(String)
      getter display_name : String

      # API
      getter api_url : String
      getter auth_header : String
      getter model_prefix : String
      getter skip_prefixes : Array(String)

      # Gateway / local detection
      getter? gateway : Bool
      getter? local : Bool
      getter detect_by_key_prefix : String
      getter detect_by_base_keyword : String
      getter? strip_model_prefix : Bool

      # Per-model parameter overrides, e.g. {"kimi-k2.5" => {"temperature" => 1.0}}
      getter model_overrides : Hash(String, Hash(String, JSON::Any))

      def initialize(
        @name,
        @keywords,
        @display_name = "",
        @api_url = "",
        @auth_header = "Authorization",
        @model_prefix = "",
        @skip_prefixes = [] of String,
        @gateway = false,
        @local = false,
        @detect_by_key_prefix = "",
        @detect_by_base_keyword = "",
        @strip_model_prefix = false,
        @model_overrides = {} of String => Hash(String, JSON::Any),
      )
        @display_name = @name.capitalize if @display_name.empty?
      end

      def label : String
        display_name
      end
    end

    # Single source of truth for all supported providers. Order = priority.
    PROVIDERS = [
      # === Gateways ===
      ProviderSpec.new(
        name: "openrouter",
        keywords: ["openrouter"],
        display_name: "OpenRouter",
        api_url: "https://openrouter.ai/api/v1/chat/completions",
        model_prefix: "openrouter",
        gateway: true,
        detect_by_key_prefix: "sk-or-",
        detect_by_base_keyword: "openrouter",
      ),

      ProviderSpec.new(
        name: "aihubmix",
        keywords: ["aihubmix"],
        display_name: "AiHubMix",
        api_url: "https://aihubmix.com/v1/chat/completions",
        gateway: true,
        detect_by_base_keyword: "aihubmix",
        strip_model_prefix: true,
      ),

      # === Standard providers ===
      ProviderSpec.new(
        name: "anthropic",
        keywords: ["anthropic", "claude"],
        display_name: "Anthropic",
        api_url: "https://api.anthropic.com/v1/messages",
        auth_header: "x-api-key",
      ),

      ProviderSpec.new(
        name: "openai",
        keywords: ["openai", "gpt", "o1", "o3", "o4"],
        display_name: "OpenAI",
        api_url: "https://api.openai.com/v1/chat/completions",
      ),

      ProviderSpec.new(
        name: "deepseek",
        keywords: ["deepseek"],
        display_name: "DeepSeek",
        api_url: "https://api.deepseek.com/v1/chat/completions",
      ),

      ProviderSpec.new(
        name: "gemini",
        keywords: ["gemini"],
        display_name: "Gemini",
        api_url: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
      ),

      ProviderSpec.new(
        name: "moonshot",
        keywords: ["moonshot", "kimi"],
        display_name: "Moonshot",
        api_url: "https://api.moonshot.ai/v1/chat/completions",
        model_overrides: {
          "kimi-k2.5" => {"temperature" => JSON::Any.new(1.0)},
        },
      ),

      ProviderSpec.new(
        name: "minimax",
        keywords: ["minimax"],
        display_name: "MiniMax",
        api_url: "https://api.minimax.io/v1/chat/completions",
      ),

      ProviderSpec.new(
        name: "groq",
        keywords: ["groq"],
        display_name: "Groq",
        api_url: "https://api.groq.com/openai/v1/chat/completions",
      ),

      # === Local ===
      ProviderSpec.new(
        name: "vllm",
        keywords: ["vllm"],
        display_name: "vLLM/Local",
        local: true,
      ),
    ]

    # Find a standard (non-gateway, non-local) provider by model name keywords.
    def self.find_by_model(model : String) : ProviderSpec?
      lower = model.downcase
      PROVIDERS.find do |provider_spec|
        next if provider_spec.gateway? || provider_spec.local?
        provider_spec.keywords.any? { |keyword| lower.includes?(keyword) }
      end
    end

    # Detect a gateway or local provider.
    #
    # Priority:
    #   1. Explicit provider_name matching a gateway/local spec.
    #   2. api_key prefix (e.g. "sk-or-" -> OpenRouter).
    #   3. api_base keyword (e.g. "aihubmix" in URL).
    def self.find_gateway(
      provider_name : String? = nil,
      api_key : String? = nil,
      api_base : String? = nil,
    ) : ProviderSpec?
      explicit_match = find_gateway_by_name(provider_name)
      return explicit_match if explicit_match

      PROVIDERS.each do |provider_spec|
        return provider_spec if match_gateway_key_prefix?(provider_spec, api_key)
        return provider_spec if match_gateway_base_keyword?(provider_spec, api_base)
      end

      nil
    end

    private def self.find_gateway_by_name(provider_name : String?) : ProviderSpec?
      return nil unless name = provider_name
      spec = find_by_name(name)
      return nil unless spec
      (spec.gateway? || spec.local?) ? spec : nil
    end

    private def self.match_gateway_key_prefix?(provider_spec : ProviderSpec, api_key : String?) : Bool
      return false unless api_key
      prefix = provider_spec.detect_by_key_prefix
      !prefix.empty? && api_key.starts_with?(prefix)
    end

    private def self.match_gateway_base_keyword?(provider_spec : ProviderSpec, api_base : String?) : Bool
      return false unless api_base
      keyword = provider_spec.detect_by_base_keyword
      !keyword.empty? && api_base.includes?(keyword)
    end

    # Find a provider spec by config name (e.g. "deepseek", "openrouter").
    def self.find_by_name(name : String) : ProviderSpec?
      PROVIDERS.find { |spec| spec.name == name }
    end
  end
end
