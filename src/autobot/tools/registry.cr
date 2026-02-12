require "./base"
require "./rate_limiter"

module Autobot::Tools
  # Registry for agent tools with rate limiting
  class Registry
    Log = ::Log.for("tools.registry")

    @tools : Hash(String, Tool)
    @rate_limiter : RateLimiter
    @session_key : String

    def initialize(@session_key : String = "default")
      @tools = {} of String => Tool
      @rate_limiter = RateLimiter.new
    end

    # Register a tool
    def register(tool : Tool) : Nil
      @tools[tool.name] = tool
      Log.info { "Registered tool: #{tool.name}" }
    end

    # Unregister a tool by name
    def unregister(name : String) : Nil
      @tools.delete(name)
      Log.info { "Unregistered tool: #{name}" }
    end

    # Get a tool by name
    def get(name : String) : Tool?
      @tools[name]?
    end

    # Check if a tool is registered
    def has?(name : String) : Bool
      @tools.has_key?(name)
    end

    # Get all tool definitions in OpenAI/Anthropic function calling format
    def definitions : Array(Hash(String, JSON::Any))
      @tools.values.map(&.to_schema)
    end

    def execute(name : String, params : Hash(String, JSON::Any)) : String
      tool = @tools[name]?

      unless tool
        return "Error: Tool '#{name}' not found"
      end

      if error = @rate_limiter.check_limit(name, @session_key)
        Log.warn { "Rate limit exceeded for tool #{name}: #{error}" }
        return "Error: #{error}"
      end

      begin
        errors = tool.validate_params(params)
        unless errors.empty?
          return "Error: Invalid parameters for tool '#{name}': #{errors.join("; ")}"
        end

        Log.info { "Executing tool: #{name}" }
        result = tool.execute(params)
        Log.info { "Tool #{name} completed successfully" }

        @rate_limiter.record_call(name, @session_key)

        result
      rescue ex : Exception
        error_msg = "Error executing #{name}"
        Log.error { error_msg }
        Log.error { ex.backtrace.join("\n") }
        error_msg
      end
    end

    # Get list of registered tool names
    def tool_names : Array(String)
      @tools.keys
    end

    # Get number of registered tools
    def size : Int32
      @tools.size
    end

    # Clear all registered tools
    def clear : Nil
      @tools.clear
      Log.info { "Cleared all tools from registry" }
    end
  end
end
