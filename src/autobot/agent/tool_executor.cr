require "../providers/provider"
require "../providers/types"
require "../tools/registry"
require "./context"

module Autobot::Agent
  # Executes the ReAct-style tool-calling loop.
  #
  # Calls the LLM, executes any requested tool calls, appends results,
  # and repeats until the LLM returns a text response or max iterations
  # is reached.
  #
  # Used by Loop (for user messages, system messages, cron) and
  # SubagentManager (for background tasks) to avoid duplicating the
  # core agentic loop logic.
  class ToolExecutor
    Log = ::Log.for("agent.tool_executor")

    MESSAGE_PREVIEW_LENGTH = 120

    record Result,
      content : String?,
      tools_used : Array(String),
      total_tokens : Int32

    def initialize(
      @provider : Providers::Provider,
      @context : Context::Builder,
      @model : String,
      @max_iterations : Int32 = 20,
    )
    end

    # Run the tool-calling loop.
    #
    # - `messages`: the full message array (system + history + user)
    # - `tools`: registry of available tools
    # - `session_key`: for per-session rate limiting (nil for subagents)
    # - `exclude_tools`: tool names to omit from LLM tool definitions
    # - `stop_after_tool`: break early after this tool is called (e.g. "message" for cron)
    def execute(
      messages : Array(Hash(String, JSON::Any)),
      tools : Tools::Registry,
      session_key : String? = nil,
      exclude_tools : Array(String)? = nil,
      stop_after_tool : String? = nil,
    ) : Result
      final_content : String? = nil
      tools_used = [] of String
      total_tokens = 0

      @max_iterations.times do
        response = call_llm(messages, tools, exclude_tools)
        total_tokens += response.usage.total_tokens

        if response.finish_reason == "guardrail_intervened"
          Log.warn { "Guardrail intervened - returning blocked message" }
          final_content = response.content
          break
        end

        if response.has_tool_calls?
          messages = process_tool_calls(messages, response, tools, tools_used, session_key)

          if stop_tool = stop_after_tool
            break if response.tool_calls.any? { |tool_call| tool_call.name == stop_tool }
          end
        else
          final_content = response.content
          break
        end
      end

      Result.new(content: final_content, tools_used: tools_used.uniq, total_tokens: total_tokens)
    end

    private def call_llm(
      messages : Array(Hash(String, JSON::Any)),
      tools : Tools::Registry,
      exclude_tools : Array(String)?,
    ) : Providers::Response
      response = @provider.chat(
        messages: messages,
        tools: tools.definitions(exclude: exclude_tools),
        model: @model
      )

      usage = response.usage
      unless usage.zero?
        Log.info { "Tokens: prompt=#{usage.prompt_tokens} completion=#{usage.completion_tokens} total=#{usage.total_tokens}" }
      end

      response
    end

    private def process_tool_calls(
      messages : Array(Hash(String, JSON::Any)),
      response : Providers::Response,
      tools : Tools::Registry,
      tools_used : Array(String),
      session_key : String?,
    ) : Array(Hash(String, JSON::Any))
      messages = @context.add_assistant_message(
        messages,
        response.content,
        response.tool_calls,
        reasoning_content: response.reasoning_content
      )

      log_reasoning(response.content)

      response.tool_calls.each do |tool_call|
        tools_used << tool_call.name
        log_tool_call(tool_call)
        result = tools.execute(tool_call.name, tool_call.arguments, session_key)
        messages = @context.add_tool_result(messages, tool_call.id, tool_call.name, result)
      end

      messages
    end

    private def log_reasoning(content : String?) : Nil
      return unless content
      return if content.empty?
      Log.debug { "LLM reasoning: #{truncate(content)}" }
    end

    private def log_tool_call(tool_call : Providers::ToolCall) : Nil
      args_preview = truncate(tool_call.arguments.to_json)
      Log.debug { "Tool call: #{tool_call.name}(#{args_preview})" }
    end

    private def truncate(text : String, max_length : Int32 = MESSAGE_PREVIEW_LENGTH) : String
      text.size > max_length ? text[0, max_length] + "..." : text
    end
  end
end
