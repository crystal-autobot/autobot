require "yaml"

module Autobot::Config
  class TelegramConfig
    include YAML::Serializable
    property? enabled : Bool = false
    property token : String = ""
    property allow_from : Array(String) = [] of String
    property? proxy : String? = nil
    property custom_commands : CustomCommandsConfig?

    def initialize
    end
  end

  struct CustomCommandEntry
    getter value : String
    getter description : String?

    def initialize(@value : String, @description : String? = nil)
    end

    def initialize(ctx : YAML::ParseContext, node : YAML::Nodes::Node)
      case node
      when YAML::Nodes::Scalar
        @value = node.value
        @description = nil
      when YAML::Nodes::Mapping
        @value = ""
        @description = nil
        nodes = node.nodes
        i = 0
        while i < nodes.size - 1
          key_node = nodes[i]
          val_node = nodes[i + 1]
          if key_node.is_a?(YAML::Nodes::Scalar) && val_node.is_a?(YAML::Nodes::Scalar)
            case key_node.value
            when "prompt", "path"
              @value = val_node.value
            when "description"
              @description = val_node.value
            end
          end
          i += 2
        end
      else
        node.raise "Expected scalar or mapping for custom command entry"
      end
    end

    def to_yaml(yaml : YAML::Nodes::Builder) : Nil
      if desc = @description
        yaml.mapping do
          yaml.scalar "prompt"
          yaml.scalar @value
          yaml.scalar "description"
          yaml.scalar desc
        end
      else
        yaml.scalar @value
      end
    end
  end

  class CustomCommandsConfig
    include YAML::Serializable
    property macros : Hash(String, CustomCommandEntry) = {} of String => CustomCommandEntry
    property scripts : Hash(String, CustomCommandEntry) = {} of String => CustomCommandEntry

    def initialize
    end
  end

  class SlackConfig
    include YAML::Serializable
    property? enabled : Bool = false
    property mode : String = "socket"
    property bot_token : String = ""
    property app_token : String = ""
    property allow_from : Array(String) = [] of String
    property group_policy : String = "mention"
    property group_allow_from : Array(String) = [] of String
    property dm : SlackDMConfig?

    def initialize
    end
  end

  class SlackDMConfig
    include YAML::Serializable
    property? enabled : Bool = false
    property policy : String = "allowlist"
    property allow_from : Array(String) = [] of String

    def initialize
    end
  end

  class WhatsAppConfig
    include YAML::Serializable
    property? enabled : Bool = false
    property bridge_url : String = "ws://localhost:3001"
    property allow_from : Array(String) = [] of String

    def initialize
    end
  end

  class ZulipConfig
    include YAML::Serializable
    property? enabled : Bool = false
    property site : String = ""
    property email : String = ""
    property api_key : String = ""
    property allow_from : Array(String) = [] of String

    def initialize
    end
  end

  class ChannelsConfig
    include YAML::Serializable
    property telegram : TelegramConfig?
    property slack : SlackConfig?
    property whatsapp : WhatsAppConfig?
    property zulip : ZulipConfig?

    def initialize
    end
  end

  class AgentDefaults
    include YAML::Serializable
    property workspace : String = "./workspace"
    property model : String = "anthropic/claude-sonnet-4-5"
    property max_tokens : Int32 = 8192
    property temperature : Float64 = 0.7
    property max_tool_iterations : Int32 = 20
    property memory_window : Int32 = 50

    def initialize
    end
  end

  class AgentsConfig
    include YAML::Serializable
    property defaults : AgentDefaults?

    def initialize
    end
  end

  class ProviderConfig
    include YAML::Serializable
    property api_key : String = ""
    property? api_base : String? = nil
    property? extra_headers : Hash(String, String)? = nil
    property? client_id : String? = nil
    property? client_secret : String? = nil
    property? refresh_token : String? = nil

    def initialize
    end

    def configured? : Bool
      !api_key.empty? || (refresh_token? != nil && !refresh_token?.try(&.empty?))
    end
  end

  class BedrockProviderConfig
    include YAML::Serializable
    property access_key_id : String = ""
    property secret_access_key : String = ""
    property session_token : String?
    property region : String = "us-east-1"
    property guardrail_id : String?
    property guardrail_version : String?

    def initialize
    end

    def configured? : Bool
      !access_key_id.empty? && !secret_access_key.empty?
    end
  end

  class ProvidersConfig
    include YAML::Serializable
    property anthropic : ProviderConfig?
    property openai : ProviderConfig?
    property openrouter : ProviderConfig?
    property deepseek : ProviderConfig?
    property groq : ProviderConfig?
    property gemini : ProviderConfig?
    property kimi : ProviderConfig?
    property vllm : ProviderConfig?
    property duckai : ProviderConfig?
    property bedrock : BedrockProviderConfig?

    def initialize
    end
  end

  class GatewayConfig
    include YAML::Serializable
    property host : String = "127.0.0.1"
    property port : Int32 = 18790

    def initialize
    end
  end

  class WebSearchConfig
    include YAML::Serializable
    property api_key : String = ""
    property max_results : Int32 = 5

    def initialize
    end
  end

  class WebToolsConfig
    include YAML::Serializable
    property search : WebSearchConfig?

    def initialize
    end
  end

  class ExecToolConfig
    include YAML::Serializable
    property timeout : Int32 = 60
    property allow_patterns : Array(String) = [] of String
    property deny_patterns : Array(String) = [] of String

    def initialize
    end
  end

  class ToolRateLimitConfig
    include YAML::Serializable
    property max_calls : Int32
    property window_seconds : Int32 = 60

    def initialize(@max_calls, @window_seconds = 60)
    end
  end

  class RateLimitConfig
    include YAML::Serializable
    property global : ToolRateLimitConfig?
    property per_tool : Hash(String, ToolRateLimitConfig)?

    def initialize
    end
  end

  class ImageConfig
    include YAML::Serializable
    property? enabled : Bool = true
    property provider : String? = nil
    property model : String? = nil
    property size : String = "1024x1024"

    def initialize
    end
  end

  class ToolsConfig
    include YAML::Serializable
    property web : WebToolsConfig?
    property exec : ExecToolConfig?
    property image : ImageConfig?
    property sandbox : String = "auto" # "auto", "bubblewrap", "docker", "none"
    property sandbox_env : Array(String) = [] of String
    property docker_image : String? = nil
    property rate_limit : RateLimitConfig?

    def initialize
    end
  end

  class CronConfig
    include YAML::Serializable
    property? enabled : Bool = true
    property store_path : String = "./cron.json"

    def initialize
    end
  end

  class McpServerConfig
    include YAML::Serializable
    property command : String = ""
    property args : Array(String) = [] of String
    property env : Hash(String, String) = {} of String => String
    property tools : Array(String) = [] of String

    def initialize
    end
  end

  class McpConfig
    include YAML::Serializable
    property servers : Hash(String, McpServerConfig) = {} of String => McpServerConfig

    def initialize
    end
  end

  class PluginConfig
    include YAML::Serializable
    property? enabled : Bool = true

    def initialize
    end
  end

  class PluginsConfig
    include YAML::Serializable
    property sqlite : PluginConfig?
    property github : PluginConfig?
    property weather : PluginConfig?

    def initialize
    end

    def enabled?(name : String) : Bool
      config = case name
               when "sqlite"  then sqlite
               when "github"  then github
               when "weather" then weather
               else                nil
               end
      config.try(&.enabled?) != false
    end
  end

  class Config
    include YAML::Serializable

    @[YAML::Field(ignore: true)]
    property config_path : Path? = nil

    property agents : AgentsConfig?
    property channels : ChannelsConfig?
    property providers : ProvidersConfig?
    property gateway : GatewayConfig?
    property tools : ToolsConfig?
    property cron : CronConfig?
    property mcp : McpConfig?
    property plugins : PluginsConfig?

    def initialize
    end

    def workspace_path : Path
      workspace_str = agents.try(&.defaults.try(&.workspace)) || "./workspace"
      if workspace_str.starts_with?("~")
        return Path[workspace_str].expand(home: true)
      end
      path = Path[workspace_str]
      if !path.absolute? && (cfg_path = config_path)
        return (cfg_path.parent / path).expand
      end
      path.expand
    end

    def default_model : String
      agents.try(&.defaults.try(&.model)) || "anthropic/claude-sonnet-4-5"
    end

    def match_provider(model : String? = nil) : Tuple(ProviderConfig?, String?)
      resolved_model = agents.try(&.defaults.try(&.model)) || "anthropic/claude-sonnet-4-5"
      model_str = (model || resolved_model).downcase

      # Bedrock is handled separately via match_bedrock
      return {nil, nil} if model_str.starts_with?("bedrock/")

      if p = providers
        {% for provider_name in %w[anthropic openai openrouter deepseek groq gemini kimi vllm duckai] %}
          provider = p.{{ provider_name.id }}
          if provider && provider.configured? && model_str.includes?({{ provider_name }})
            return {provider, {{ provider_name }}}
          end
        {% end %}
        {% for provider_name in %w[anthropic openai openrouter deepseek groq gemini kimi vllm duckai] %}
          provider = p.{{ provider_name.id }}
          if provider && provider.configured?
            return {provider, {{ provider_name }}}
          end
        {% end %}
      end
      {nil, nil}
    end

    def match_bedrock(model : String? = nil) : BedrockProviderConfig?
      resolved_model = agents.try(&.defaults.try(&.model)) || "anthropic/claude-sonnet-4-5"
      model_str = (model || resolved_model).downcase
      return nil unless model_str.starts_with?("bedrock/")

      bedrock = providers.try(&.bedrock)
      return nil unless bedrock && bedrock.configured?
      bedrock
    end

    def provider_by_name(name : String) : ProviderConfig?
      return nil unless p = providers
      normalized = name.downcase
      {% for provider_name in %w[anthropic openai openrouter deepseek groq gemini kimi vllm duckai] %}
        if normalized == {{ provider_name }}
          provider = p.{{ provider_name.id }}
          return provider if provider && provider.configured?
        end
      {% end %}
      nil
    end

    def plugin_enabled?(name : String) : Bool
      plugins.try(&.enabled?(name)) != false
    end

    def validate! : Nil
      has_provider = false
      if p = providers
        {% for provider_name in %w[anthropic openai openrouter deepseek groq gemini kimi vllm duckai] %}
          provider = p.{{ provider_name.id }}
          has_provider ||= (provider && provider.configured?)
        {% end %}
        has_provider ||= (p.bedrock.try(&.configured?) || false)
      end

      unless has_provider
        raise "No LLM provider configured. Please set an API key in config.yml"
      end
    end
  end
end
