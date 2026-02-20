require "./base"
require "./rate_limiter"
require "./sandbox_executor"

module Autobot::Tools
  # Registry for agent tools with rate limiting
  class Registry
    Log = ::Log.for("tools.registry")

    @tools : Hash(String, Tool)
    @rate_limiter : RateLimiter
    @session_key : String
    @sandbox_executor : SandboxExecutor?

    def initialize(@session_key : String = "default")
      @tools = {} of String => Tool
      @rate_limiter = RateLimiter.new
      @sandbox_executor = nil
    end

    # Register a tool
    def register(tool : Tool) : Nil
      @tools[tool.name] = tool
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

    # Get all tool definitions in OpenAI/Anthropic function calling format.
    # Optionally exclude specific tools by name.
    def definitions(exclude : Array(String)? = nil) : Array(Hash(String, JSON::Any))
      tools = @tools.values
      tools = tools.reject { |tool| exclude.try(&.includes?(tool.name)) } if exclude
      tools.map(&.to_schema)
    end

    def execute(name : String, params : Hash(String, JSON::Any), session_key : String? = nil) : String
      tool = @tools[name]?

      unless tool
        return "Error: Tool '#{name}' not found"
      end

      # Use provided session key or fall back to instance default
      effective_session_key = session_key || @session_key

      if error = @rate_limiter.check_limit(name, effective_session_key)
        Log.warn { "Rate limit exceeded for tool #{name}: #{error}" }
        return "Error: #{error}"
      end

      begin
        errors = tool.validate_params(params)
        unless errors.empty?
          return "Error: Invalid parameters for tool '#{name}': #{errors.join("; ")}"
        end

        if path = params["path"]?.try(&.as_s?)
          Log.debug { "Executing tool: #{name} (#{path})" }
        else
          Log.debug { "Executing tool: #{name}" }
        end
        result = tool.execute(params)

        # Log based on result status
        case result.status
        when ToolResult::Status::Success
          Log.debug { "Tool #{name} completed successfully" }
        when ToolResult::Status::AccessDenied
          Log.warn { "Tool #{name} ACCESS DENIED: #{result.content.split('\n').first}" }
        when ToolResult::Status::Error
          Log.warn { "Tool #{name} failed: #{result.content.split('\n').first}" }
        end

        @rate_limiter.record_call(name, effective_session_key)

        result.to_s
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

    # Set sandbox executor for plugin access
    def sandbox_executor=(executor : SandboxExecutor?)
      @sandbox_executor = executor
    end

    # Get sandbox executor
    def sandbox_executor : SandboxExecutor?
      @sandbox_executor
    end
  end
end
