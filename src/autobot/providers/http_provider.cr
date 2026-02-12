require "http/client"
require "json"
require "uri"
require "log"
require "../constants"

module Autobot
  module Providers
    # HTTP-based LLM provider supporting OpenAI-compatible chat completion APIs.
    #
    # Works with: OpenAI, DeepSeek, Groq, Moonshot, MiniMax, OpenRouter,
    # AiHubMix, vLLM, and any OpenAI-compatible endpoint.
    #
    # For Anthropic, uses the Messages API with automatic format conversion.
    class HttpProvider < Provider
      Log = ::Log.for(self)

      CONNECT_TIMEOUT       = 30.seconds
      READ_TIMEOUT          = 300.seconds
      USER_AGENT            = "Autobot/#{VERSION}"
      ANTHROPIC_API_VERSION = "2023-06-01"

      getter model : String
      getter extra_headers : Hash(String, String)

      @spec : ProviderSpec?
      @gateway : ProviderSpec?

      def initialize(
        api_key : String,
        api_base : String? = nil,
        @model : String = "anthropic/claude-sonnet-4-5-20250929",
        @extra_headers = {} of String => String,
        provider_name : String? = nil,
      )
        super(api_key, api_base)
        @gateway = Providers.find_gateway(provider_name, api_key, api_base)
        @spec = @gateway || Providers.find_by_model(@model)
      end

      def default_model : String
        @model
      end

      def chat(
        messages : Array(Hash(String, JSON::Any)),
        tools : Array(Hash(String, JSON::Any))? = nil,
        model : String? = nil,
        max_tokens : Int32 = DEFAULT_MAX_TOKENS,
        temperature : Float64 = DEFAULT_TEMPERATURE,
      ) : Response
        effective_model = model || @model
        spec = resolve_spec(effective_model)

        if anthropic_native?(spec, effective_model)
          chat_anthropic(messages, tools, effective_model, max_tokens, temperature, spec)
        else
          chat_openai(messages, tools, effective_model, max_tokens, temperature, spec)
        end
      rescue ex
        Log.error { "LLM request failed: #{ex.message}" }
        Response.new(content: "Error calling LLM: #{ex.message}", finish_reason: "error")
      end

      # -----------------------------------------------------------------
      # OpenAI-compatible request
      # -----------------------------------------------------------------
      private def chat_openai(
        messages, tools, model, max_tokens, temperature, spec,
      ) : Response
        body = build_openai_body(messages, tools, model, max_tokens, temperature, spec)
        url = resolve_url(spec)

        headers = HTTP::Headers{
          "Content-Type" => "application/json",
          "User-Agent"   => USER_AGENT,
        }
        apply_auth_headers(headers, spec)

        Log.debug { "POST #{url} model=#{model}" }
        response = http_post(url, headers, body.to_json)
        parse_openai_response(response.body)
      end

      private def build_openai_body(messages, tools, model, max_tokens, temperature, spec)
        body = {
          "model"       => JSON::Any.new(resolve_model_name(model, spec)),
          "messages"    => JSON::Any.new(messages.map { |message| JSON::Any.new(message.transform_values { |value| value }) }),
          "max_tokens"  => JSON::Any.new(max_tokens.to_i64),
          "temperature" => JSON::Any.new(temperature),
        } of String => JSON::Any

        apply_model_overrides(model, spec, body)

        if tools && !tools.empty?
          body["tools"] = JSON::Any.new(tools.map { |tool_def| JSON::Any.new(tool_def.transform_values { |value| value }) })
          body["tool_choice"] = JSON::Any.new("auto")
        end

        body
      end

      private def parse_openai_response(body : String) : Response
        json = JSON.parse(body)

        if error = json["error"]?
          msg = error["message"]?.try(&.as_s?) || error.to_json
          return Response.new(content: "API error: #{msg}", finish_reason: "error")
        end

        choice = json["choices"][0]
        message = choice["message"]
        finish = choice["finish_reason"]?.try(&.as_s?) || "stop"

        content = message["content"]?.try(&.as_s?)
        reasoning = message["reasoning_content"]?.try(&.as_s?)

        tool_calls = parse_tool_calls(message["tool_calls"]?)
        usage = parse_usage(json["usage"]?)

        Response.new(
          content: content,
          tool_calls: tool_calls,
          finish_reason: finish,
          usage: usage,
          reasoning_content: reasoning,
        )
      end

      # -----------------------------------------------------------------
      # Anthropic Messages API
      # -----------------------------------------------------------------
      private def chat_anthropic(
        messages, tools, model, max_tokens, temperature, spec,
      ) : Response
        body = build_anthropic_body(messages, tools, model, max_tokens, temperature)
        url = resolve_url(spec)

        headers = HTTP::Headers{
          "Content-Type"      => "application/json",
          "User-Agent"        => USER_AGENT,
          "anthropic-version" => ANTHROPIC_API_VERSION,
        }
        apply_auth_headers(headers, spec)

        Log.debug { "POST #{url} model=#{model} (anthropic)" }
        response = http_post(url, headers, body.to_json)
        parse_anthropic_response(response.body)
      end

      private def build_anthropic_body(messages, tools, model, max_tokens, temperature)
        system_text = extract_system_prompt(messages)
        converted = convert_to_anthropic_messages(messages)

        # Strip provider prefix for Anthropic API (e.g. "anthropic/claude-sonnet-4-5" -> "claude-sonnet-4-5")
        bare_model = model.includes?("/") ? model.split("/", 2).last : model

        body = {
          "model"       => JSON::Any.new(bare_model),
          "messages"    => JSON::Any.new(converted),
          "max_tokens"  => JSON::Any.new(max_tokens.to_i64),
          "temperature" => JSON::Any.new(temperature),
        } of String => JSON::Any

        body["system"] = JSON::Any.new(system_text) unless system_text.empty?

        if tools && !tools.empty?
          body["tools"] = JSON::Any.new(convert_tools_to_anthropic(tools))
          body["tool_choice"] = JSON::Any.new({"type" => JSON::Any.new("auto")} of String => JSON::Any)
        end

        body
      end

      private def extract_system_prompt(messages) : String
        messages
          .select { |message| message["role"]?.try(&.as_s?) == Constants::ROLE_SYSTEM }
          .compact_map { |message| message["content"]?.try(&.as_s?) }
          .join("\n\n")
      end

      private def convert_to_anthropic_messages(messages) : Array(JSON::Any)
        messages
          .reject { |message| message["role"]?.try(&.as_s?) == Constants::ROLE_SYSTEM }
          .map { |message| convert_single_anthropic_message(message) }
      end

      private def convert_single_anthropic_message(message : Hash(String, JSON::Any)) : JSON::Any
        role = message["role"]?.try(&.as_s?) || Constants::ROLE_USER
        return build_anthropic_tool_result_message(message) if role == Constants::ROLE_TOOL
        return build_anthropic_assistant_tool_message(message) if role == Constants::ROLE_ASSISTANT && message["tool_calls"]?
        build_anthropic_regular_message(role, message["content"]? || JSON::Any.new(""))
      end

      private def build_anthropic_tool_result_message(message : Hash(String, JSON::Any)) : JSON::Any
        tool_call_id = message["tool_call_id"]?.try(&.as_s?) || ""
        content_text = message["content"]?.try(&.as_s?) || ""

        JSON::Any.new({
          "role"    => JSON::Any.new(Constants::ROLE_USER),
          "content" => JSON::Any.new([
            JSON::Any.new({
              "type"        => JSON::Any.new("tool_result"),
              "tool_use_id" => JSON::Any.new(tool_call_id),
              "content"     => JSON::Any.new(content_text),
            } of String => JSON::Any),
          ] of JSON::Any),
        } of String => JSON::Any)
      end

      private def build_anthropic_assistant_tool_message(message : Hash(String, JSON::Any)) : JSON::Any
        JSON::Any.new({
          "role"    => JSON::Any.new(Constants::ROLE_ASSISTANT),
          "content" => JSON::Any.new(build_assistant_content_blocks(message)),
        } of String => JSON::Any)
      end

      private def build_assistant_content_blocks(message : Hash(String, JSON::Any)) : Array(JSON::Any)
        content_blocks = [] of JSON::Any

        if text = message["content"]?.try(&.as_s?)
          content_blocks << JSON::Any.new({
            "type" => JSON::Any.new("text"),
            "text" => JSON::Any.new(text),
          } of String => JSON::Any) unless text.empty?
        end

        if tc_array = message["tool_calls"]?.try(&.as_a?)
          tc_array.each do |tool_call|
            block = build_anthropic_tool_use_block(tool_call)
            content_blocks << block if block
          end
        end

        content_blocks
      end

      private def build_anthropic_tool_use_block(tool_call : JSON::Any) : JSON::Any?
        func = tool_call["function"]?
        return nil unless func

        JSON::Any.new({
          "type"  => JSON::Any.new("tool_use"),
          "id"    => tool_call["id"]? || JSON::Any.new(""),
          "name"  => func["name"]? || JSON::Any.new(""),
          "input" => parse_arguments_field(func["arguments"]?),
        } of String => JSON::Any)
      end

      private def build_anthropic_regular_message(role : String, content : JSON::Any) : JSON::Any
        JSON::Any.new({
          "role"    => JSON::Any.new(role),
          "content" => content,
        } of String => JSON::Any)
      end

      private def convert_tools_to_anthropic(tools) : Array(JSON::Any)
        tools.map do |tool_def|
          func = tool_def["function"]?
          next JSON::Any.new(nil) unless func
          JSON::Any.new({
            "name"         => func["name"]? || JSON::Any.new(""),
            "description"  => func["description"]? || JSON::Any.new(""),
            "input_schema" => func["parameters"]? || JSON::Any.new({} of String => JSON::Any),
          } of String => JSON::Any)
        end
      end

      private def parse_anthropic_response(body : String) : Response
        json = JSON.parse(body)
        if error_response = parse_anthropic_error(json, body)
          return error_response
        end

        text_parts, tool_calls = parse_anthropic_content_blocks(json["content"]?.try(&.as_a?) || [] of JSON::Any)
        build_anthropic_response(json, text_parts, tool_calls)
      end

      private def parse_anthropic_error(json : JSON::Any, body : String) : Response?
        return nil unless json["type"]?.try(&.as_s?) == "error"
        msg = json["error"]?.try { |error| error["message"]?.try(&.as_s?) } || body
        Response.new(content: "API error: #{msg}", finish_reason: "error")
      end

      private def parse_anthropic_content_blocks(content_blocks : Array(JSON::Any)) : {Array(String), Array(ToolCall)}
        text_parts = [] of String
        tool_calls = [] of ToolCall

        content_blocks.each do |block|
          append_anthropic_content_block(block, text_parts, tool_calls)
        end

        {text_parts, tool_calls}
      end

      private def append_anthropic_content_block(block : JSON::Any, text_parts : Array(String), tool_calls : Array(ToolCall)) : Nil
        case block["type"]?.try(&.as_s?)
        when "text"
          text_parts << (block["text"]?.try(&.as_s?) || "")
        when "tool_use"
          if tool_call = parse_anthropic_tool_use(block)
            tool_calls << tool_call
          end
        end
      end

      private def parse_anthropic_tool_use(block : JSON::Any) : ToolCall?
        id = block["id"]?.try(&.as_s?) || ""
        name = block["name"]?.try(&.as_s?) || ""
        input = block["input"]?.try(&.as_h?) || {} of String => JSON::Any
        args = input.transform_values { |value| value.as(JSON::Any) }
        ToolCall.new(id: id, name: name, arguments: args)
      end

      private def build_anthropic_response(json : JSON::Any, text_parts : Array(String), tool_calls : Array(ToolCall)) : Response
        stop_reason = json["stop_reason"]?.try(&.as_s?) || "end_turn"
        finish = stop_reason == "tool_use" ? "tool_calls" : "stop"
        usage = parse_anthropic_usage(json["usage"]?)

        Response.new(
          content: text_parts.empty? ? nil : text_parts.join("\n"),
          tool_calls: tool_calls,
          finish_reason: finish,
          usage: usage,
        )
      end

      # -----------------------------------------------------------------
      # Shared helpers
      # -----------------------------------------------------------------
      private def anthropic_native?(spec : ProviderSpec?, model : String) : Bool
        return false if @gateway
        return false unless spec
        spec.name == "anthropic"
      end

      private def resolve_spec(model : String) : ProviderSpec?
        @gateway || Providers.find_by_model(model)
      end

      private def resolve_url(spec : ProviderSpec?) : String
        if base = @api_base
          base = base.rstrip('/')
          return "#{base}/chat/completions" unless base.ends_with?("/chat/completions") || base.ends_with?("/messages")
          return base
        end

        spec.try(&.api_url) || "https://api.openai.com/v1/chat/completions"
      end

      private def resolve_model_name(model : String, spec : ProviderSpec?) : String
        if gw = @gateway
          m = gw.strip_model_prefix? ? model.split("/").last : model
          prefix = gw.model_prefix
          return "#{prefix}/#{m}" if !prefix.empty? && !m.starts_with?("#{prefix}/")
          return m
        end

        if s = spec
          prefix = s.model_prefix
          if !prefix.empty? && !s.skip_prefixes.any? { |skip_prefix| model.starts_with?(skip_prefix) }
            return "#{prefix}/#{model}"
          end
        end

        model
      end

      private def apply_model_overrides(model : String, spec : ProviderSpec?, body)
        return unless s = spec
        lower = model.downcase
        s.model_overrides.each do |pattern, overrides|
          if lower.includes?(pattern)
            overrides.each { |k, v| body[k] = v }
            return
          end
        end
      end

      private def apply_auth_headers(headers : HTTP::Headers, spec : ProviderSpec?)
        auth_header = spec.try(&.auth_header) || "Authorization"
        if auth_header == "x-api-key"
          headers["x-api-key"] = @api_key
        else
          headers["Authorization"] = "Bearer #{@api_key}"
        end

        @extra_headers.each { |k, v| headers[k] = v }
      end

      private def parse_tool_calls(node : JSON::Any?) : Array(ToolCall)
        return [] of ToolCall unless arr = node.try(&.as_a?)

        arr.compact_map do |tool_call|
          func = tool_call["function"]?
          next unless func

          id = tool_call["id"]?.try(&.as_s?) || ""
          name = func["name"]?.try(&.as_s?) || ""
          args = parse_arguments_field(func["arguments"]?)

          ToolCall.new(id: id, name: name, arguments: args.as_h? || {} of String => JSON::Any)
        end
      end

      private def parse_arguments_field(node : JSON::Any?) : JSON::Any
        return JSON::Any.new({} of String => JSON::Any) unless node

        if str = node.as_s?
          begin
            JSON.parse(str)
          rescue
            JSON::Any.new({"raw" => JSON::Any.new(str)} of String => JSON::Any)
          end
        else
          node
        end
      end

      private def parse_usage(node : JSON::Any?) : TokenUsage
        return TokenUsage.new unless node
        TokenUsage.new(
          prompt_tokens: node["prompt_tokens"]?.try(&.as_i?) || 0,
          completion_tokens: node["completion_tokens"]?.try(&.as_i?) || 0,
          total_tokens: node["total_tokens"]?.try(&.as_i?) || 0,
        )
      end

      private def parse_anthropic_usage(node : JSON::Any?) : TokenUsage
        return TokenUsage.new unless node
        input = node["input_tokens"]?.try(&.as_i?) || 0
        output = node["output_tokens"]?.try(&.as_i?) || 0
        TokenUsage.new(
          prompt_tokens: input,
          completion_tokens: output,
          total_tokens: input + output,
        )
      end

      private def http_post(url : String, headers : HTTP::Headers, body : String) : HTTP::Client::Response
        uri = URI.parse(url)
        tls = uri.scheme == "https"

        host = uri.host
        raise "Invalid URL: missing host in '#{url}'" unless host

        client = HTTP::Client.new(host, port: uri.port, tls: tls)
        client.connect_timeout = CONNECT_TIMEOUT
        client.read_timeout = READ_TIMEOUT

        path = uri.request_target
        response = client.post(path, headers: headers, body: body)

        Log.debug { "Response #{response.status_code} (#{response.body.size} bytes)" }
        response
      ensure
        client.try(&.close)
      end
    end
  end
end
