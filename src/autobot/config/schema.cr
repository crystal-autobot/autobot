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

  # A custom command entry that supports both simple string and rich format.
  #
  # Simple format (backward compatible):
  #   summarize: "Summarize the conversation"
  #
  # Rich format (with description):
  #   summarize:
  #     prompt: "Summarize the conversation"      # use "prompt" for macros
  #     description: "Summarize the conversation"
  #
  #   deploy:
  #     path: "/home/user/scripts/deploy.sh"       # use "path" for scripts
  #     description: "Deploy application to production"
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

    def initialize
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
    property vllm : ProviderConfig?
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

    def initialize
    end
  end

  class ToolsConfig
    include YAML::Serializable
    property web : WebToolsConfig?
    property exec : ExecToolConfig?
    property sandbox : String = "auto" # "auto", "bubblewrap", "docker", "none"
    property docker_image : String? = nil

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

  # Configuration for a single MCP server process.
  #
  #   garmin:
  #     command: "uvx"
  #     args: ["--python", "3.12", "garmin-mcp"]
  #     env:
  #       GARMIN_EMAIL: "${GARMIN_EMAIL}"
  #     tools: ["get_activities*", "get_heart_rate*"]  # optional allowlist
  class McpServerConfig
    include YAML::Serializable
    property command : String = ""
    property args : Array(String) = [] of String
    property env : Hash(String, String) = {} of String => String
    property tools : Array(String) = [] of String

    def initialize
    end
  end

  # Top-level MCP configuration containing named server definitions.
  class McpConfig
    include YAML::Serializable
    property servers : Hash(String, McpServerConfig) = {} of String => McpServerConfig

    def initialize
    end
  end

  class Config
    include YAML::Serializable
    property agents : AgentsConfig?
    property channels : ChannelsConfig?
    property providers : ProvidersConfig?
    property gateway : GatewayConfig?
    property tools : ToolsConfig?
    property cron : CronConfig?
    property mcp : McpConfig?

    def initialize
    end

    def workspace_path : Path
      workspace_str = agents.try(&.defaults.try(&.workspace)) || "./workspace"
      Path[workspace_str].expand(home: true)
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
        {% for provider_name in %w[anthropic openai openrouter deepseek groq gemini vllm] %}
          provider = p.{{ provider_name.id }}
          if provider && provider.api_key != "" && model_str.includes?({{ provider_name }})
            return {provider, {{ provider_name }}}
          end
        {% end %}
        {% for provider_name in %w[anthropic openai openrouter deepseek groq gemini vllm] %}
          provider = p.{{ provider_name.id }}
          if provider && provider.api_key != ""
            return {provider, {{ provider_name }}}
          end
        {% end %}
      end
      {nil, nil}
    end

    # Returns Bedrock config if the model uses the bedrock provider.
    def match_bedrock(model : String? = nil) : BedrockProviderConfig?
      resolved_model = agents.try(&.defaults.try(&.model)) || "anthropic/claude-sonnet-4-5"
      model_str = (model || resolved_model).downcase
      return nil unless model_str.starts_with?("bedrock/")

      bedrock = providers.try(&.bedrock)
      return nil unless bedrock && bedrock.configured?
      bedrock
    end

    def validate! : Nil
      has_provider = false
      if p = providers
        {% for provider_name in %w[anthropic openai openrouter deepseek groq gemini vllm] %}
          provider = p.{{ provider_name.id }}
          has_provider ||= (provider && provider.api_key != "")
        {% end %}
        has_provider ||= (p.bedrock.try(&.configured?) || false)
      end
      unless has_provider
        raise "No LLM provider configured. Please set an API key in config.yml"
      end
    end
  end
end
