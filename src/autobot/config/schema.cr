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

  class CustomCommandsConfig
    include YAML::Serializable
    property macros : Hash(String, String) = {} of String => String
    property scripts : Hash(String, String) = {} of String => String

    def initialize
    end
  end

  class SlackConfig
    include YAML::Serializable
    property? enabled : Bool = false
    property mode : String = "socket"
    property bot_token : String = ""
    property app_token : String = ""
    property group_policy : String = "mention"
    property group_allow_from : Array(String) = [] of String
    property dm : SlackDMConfig?

    def initialize
    end
  end

  class SlackDMConfig
    include YAML::Serializable
    property? enabled : Bool = true
    property policy : String = "open"
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

  class ChannelsConfig
    include YAML::Serializable
    property telegram : TelegramConfig?
    property slack : SlackConfig?
    property whatsapp : WhatsAppConfig?

    def initialize
    end
  end

  class AgentDefaults
    include YAML::Serializable
    property workspace : String = "~/.config/autobot/workspace"
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

  class ProvidersConfig
    include YAML::Serializable
    property anthropic : ProviderConfig?
    property openai : ProviderConfig?
    property openrouter : ProviderConfig?
    property deepseek : ProviderConfig?
    property groq : ProviderConfig?
    property gemini : ProviderConfig?
    property vllm : ProviderConfig?

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
    property? restrict_to_workspace : Bool = true

    def initialize
    end
  end

  class CronConfig
    include YAML::Serializable
    property? enabled : Bool = true
    property store_path : String = "~/.config/autobot/cron.json"

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

    def initialize
    end

    def workspace_path : Path
      workspace_str = agents.try(&.defaults.try(&.workspace)) || "~/.config/autobot/workspace"
      Path[workspace_str].expand(home: true)
    end

    def default_model : String
      agents.try(&.defaults.try(&.model)) || "anthropic/claude-sonnet-4-5"
    end

    def match_provider(model : String? = nil) : Tuple(ProviderConfig?, String?)
      default_model = agents.try(&.defaults.try(&.model)) || "anthropic/claude-sonnet-4-5"
      model_str = (model || default_model).downcase
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

    def validate! : Nil
      has_provider = false
      if p = providers
        {% for provider_name in %w[anthropic openai openrouter deepseek groq gemini vllm] %}
          provider = p.{{ provider_name.id }}
          has_provider ||= (provider && provider.api_key != "")
        {% end %}
      end
      unless has_provider
        raise "No LLM provider configured. Please set an API key in config.yml"
      end
    end
  end
end
