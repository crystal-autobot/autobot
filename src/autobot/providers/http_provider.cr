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
      SSE_DATA_PREFIX       = "data: "

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
        bare_model = strip_provider_prefix(effective_model)

        if anthropic_native?(spec, effective_model)
          chat_anthropic(messages, tools, bare_model, max_tokens, temperature, spec)
        else
          chat_compatible(messages, tools, bare_model, max_tokens, temperature, spec)
        end
      rescue ex
        Log.error { "LLM request failed: #{ex.message}" }
        Log.debug { ex.inspect_with_backtrace }
        Response.new(content: "Error calling LLM: #{ex.message}", finish_reason: "error")
      end

      def chat_streaming(
        messages : Array(Hash(String, JSON::Any)),
        tools : Array(Hash(String, JSON::Any))? = nil,
        model : String? = nil,
        max_tokens : Int32 = DEFAULT_MAX_TOKENS,
        temperature : Float64 = DEFAULT_TEMPERATURE,
        &on_delta : StreamCallback
      ) : Response
        effective_model = model || @model
        spec = resolve_spec(effective_model)
        bare_model = strip_provider_prefix(effective_model)

        if anthropic_native?(spec, effective_model)
          chat_anthropic_streaming(messages, tools, bare_model, max_tokens, temperature, spec, &on_delta)
        else
          chat_compatible_streaming(messages, tools, bare_model, max_tokens, temperature, spec, &on_delta)
        end
      rescue ex
        Log.error { "LLM streaming request failed: #{ex.message}" }
        Log.debug { ex.inspect_with_backtrace }
        Response.new(content: "Error calling LLM: #{ex.message}", finish_reason: "error")
      end

      # -----------------------------------------------------------------
      # OpenAI-compatible (standard) request
      # -----------------------------------------------------------------
      private def chat_compatible(
        messages, tools, model, max_tokens, temperature, spec,
      ) : Response
        body = build_compatible_body(messages, tools, model, max_tokens, temperature, spec)
        url = resolve_url(spec)

        headers = HTTP::Headers{
          "Content-Type" => "application/json",
          "User-Agent"   => USER_AGENT,
        }
        apply_auth_headers(headers, spec)

        Log.debug { "POST #{url} model=#{model}" }
        response = http_post(url, headers, body.to_json)
        parse_compatible_response(response.body)
      end

      private def build_compatible_body(messages, tools, model, max_tokens, temperature, spec)
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

      private def parse_compatible_response(body : String) : Response
        json = JSON.parse(body)

        if error = extract_error(json)
          return Response.new(content: "API error: #{error}", finish_reason: "error")
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

        body = {
          "model"       => JSON::Any.new(model),
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
          "content" => convert_content_for_anthropic(content),
        } of String => JSON::Any)
      end

      private def convert_content_for_anthropic(content : JSON::Any) : JSON::Any
        return content unless blocks = content.as_a?

        converted = blocks.map do |block|
          if block["type"]?.try(&.as_s?) == "image_url"
            convert_image_url_to_anthropic(block)
          else
            block
          end
        end

        JSON::Any.new(converted)
      end

      private def convert_image_url_to_anthropic(block : JSON::Any) : JSON::Any
        url = block["image_url"]?.try { |image_url| image_url["url"]?.try(&.as_s?) } || ""

        media_type, data = parse_data_uri(url)

        JSON::Any.new({
          "type"   => JSON::Any.new("image"),
          "source" => JSON::Any.new({
            "type"       => JSON::Any.new("base64"),
            "media_type" => JSON::Any.new(media_type),
            "data"       => JSON::Any.new(data),
          } of String => JSON::Any),
        } of String => JSON::Any)
      end

      private def parse_data_uri(url : String) : {String, String}
        if url.starts_with?("data:") && url.includes?(";base64,")
          parts = url.split(";base64,", 2)
          media_type = parts[0].lchop("data:")
          data = parts[1]
          {media_type, data}
        else
          {"image/jpeg", url}
        end
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

      # Extracts an error message from an OpenAI-compatible response.
      # Handles both standard `{"error": {...}}` and array-wrapped
      # `[{"error": {...}}]` formats (e.g. Google Gemini).
      private def extract_error(json : JSON::Any) : String?
        root = json.as_a?.try(&.first?) || json
        error = root["error"]?
        return nil unless error
        error["message"]?.try(&.as_s?) || error.to_json
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
      # OpenAI-compatible streaming
      # -----------------------------------------------------------------
      private def chat_compatible_streaming(
        messages, tools, model, max_tokens, temperature, spec,
        &on_delta : StreamCallback
      ) : Response
        body = build_compatible_body(messages, tools, model, max_tokens, temperature, spec)
        body["stream"] = JSON::Any.new(true)
        body["stream_options"] = JSON::Any.new(
          {"include_usage" => JSON::Any.new(true)} of String => JSON::Any
        )
        url = resolve_url(spec)

        headers = HTTP::Headers{
          "Content-Type" => "application/json",
          "User-Agent"   => USER_AGENT,
        }
        apply_auth_headers(headers, spec)

        Log.debug { "POST #{url} model=#{model} (streaming)" }
        http_post_streaming(url, headers, body.to_json) do |io|
          parse_compatible_sse(io, &on_delta)
        end
      end

      private def parse_compatible_sse(io : IO, &on_delta : StreamCallback) : Response
        content = String::Builder.new
        tool_calls_map = {} of Int32 => {id: String, name: String, args: String::Builder}
        finish_reason = "stop"
        usage = TokenUsage.new

        read_sse_events(io) do |data|
          next if data == "[DONE]"

          json = JSON.parse(data)
          if u = json_hash(json, "usage")
            usage = parse_usage(JSON::Any.new(u))
          end

          choice = json["choices"]?.try(&.as_a?).try(&.first?).try(&.as_h?)
          next unless choice

          if reason = choice["finish_reason"]?.try(&.as_s?)
            finish_reason = reason
          end

          delta = json_hash(JSON::Any.new(choice), "delta")
          next unless delta

          accumulate_compatible_delta(JSON::Any.new(delta), content, tool_calls_map, &on_delta)
        end

        finish_reason = "tool_calls" unless tool_calls_map.empty?
        build_streaming_response(content, tool_calls_map, finish_reason, usage)
      end

      private def accumulate_compatible_delta(
        delta : JSON::Any,
        content : String::Builder,
        tool_calls_map : Hash(Int32, {id: String, name: String, args: String::Builder}),
        &on_delta : StreamCallback
      ) : Nil
        if text = delta["content"]?.try(&.as_s?)
          content << text
          on_delta.call(text)
        end

        if tc_arr = delta["tool_calls"]?.try(&.as_a?)
          tc_arr.each do |tool_call|
            idx = tool_call["index"]?.try(&.as_i?) || 0
            accumulate_tool_call_fragment(tool_call, idx, tool_calls_map)
          end
        end
      end

      private def accumulate_tool_call_fragment(
        fragment : JSON::Any,
        idx : Int32,
        tool_calls_map : Hash(Int32, {id: String, name: String, args: String::Builder}),
      ) : Nil
        unless tool_calls_map.has_key?(idx)
          id = fragment["id"]?.try(&.as_s?) || ""
          func = json_hash(fragment, "function")
          name = func.try { |func_hash| func_hash["name"]?.try(&.as_s?) } || ""
          tool_calls_map[idx] = {id: id, name: name, args: String::Builder.new}
        end

        if args_chunk = json_hash(fragment, "function").try { |func_hash| func_hash["arguments"]?.try(&.as_s?) }
          tool_calls_map[idx][:args] << args_chunk
        end
      end

      # -----------------------------------------------------------------
      # Anthropic streaming
      # -----------------------------------------------------------------
      private def chat_anthropic_streaming(
        messages, tools, model, max_tokens, temperature, spec,
        &on_delta : StreamCallback
      ) : Response
        body = build_anthropic_body(messages, tools, model, max_tokens, temperature)
        body["stream"] = JSON::Any.new(true)
        url = resolve_url(spec)

        headers = HTTP::Headers{
          "Content-Type"      => "application/json",
          "User-Agent"        => USER_AGENT,
          "anthropic-version" => ANTHROPIC_API_VERSION,
        }
        apply_auth_headers(headers, spec)

        Log.debug { "POST #{url} model=#{model} (anthropic streaming)" }
        http_post_streaming(url, headers, body.to_json) do |io|
          parse_anthropic_sse(io, &on_delta)
        end
      end

      private def parse_anthropic_sse(io : IO, &on_delta : StreamCallback) : Response
        state = AnthropicStreamState.new
        read_sse_events(io) do |data|
          process_anthropic_event(data, state, &on_delta)
        end
        state.to_response
      end

      private def process_anthropic_event(
        data : String,
        state : AnthropicStreamState,
        &on_delta : StreamCallback
      ) : Nil
        json = JSON.parse(data)
        event_type = json["type"]?.try(&.as_s?) || ""

        case event_type
        when "message_start"
          state.update_usage_from_message(json)
        when "content_block_start"
          state.start_content_block(json)
        when "content_block_delta"
          state.apply_delta(json, &on_delta)
        when "content_block_stop"
          state.finish_content_block
        when "message_delta"
          state.update_stop_reason(json)
        when "error"
          error_msg = json_hash(json, "error").try { |err| err["message"]?.try(&.as_s?) } || "Unknown streaming error"
          state.record_error(error_msg)
        end
      end

      # Tracks accumulated state during Anthropic SSE streaming.
      private class AnthropicStreamState
        getter text_parts : Array(String) = [] of String
        getter tool_calls : Array(ToolCall) = [] of ToolCall
        getter usage : TokenUsage = TokenUsage.new
        getter stop_reason : String = "end_turn"
        getter? error : Bool = false

        @current_block_type : String? = nil
        @current_block_id : String = ""
        @current_block_name : String = ""
        @current_text : String::Builder = String::Builder.new
        @current_args : String::Builder = String::Builder.new

        def update_usage_from_message(json : JSON::Any) : Nil
          if u = hash_field(hash_field(json, "message"), "usage")
            input = u["input_tokens"]?.try(&.as_i?) || 0
            @usage = TokenUsage.new(prompt_tokens: input)
          end
        end

        def start_content_block(json : JSON::Any) : Nil
          block = hash_field(json, "content_block")
          return unless block

          @current_block_type = block["type"]?.try(&.as_s?)
          @current_text = String::Builder.new
          @current_args = String::Builder.new
          @current_block_id = block["id"]?.try(&.as_s?) || ""
          @current_block_name = block["name"]?.try(&.as_s?) || ""
        end

        def apply_delta(json : JSON::Any, &on_delta : StreamCallback) : Nil
          delta = hash_field(json, "delta")
          return unless delta

          case delta["type"]?.try(&.as_s?)
          when "text_delta"
            if text = delta["text"]?.try(&.as_s?)
              @current_text << text
              on_delta.call(text)
            end
          when "input_json_delta"
            if partial = delta["partial_json"]?.try(&.as_s?)
              @current_args << partial
            end
          end
        end

        def finish_content_block : Nil
          case @current_block_type
          when "text"
            text = @current_text.to_s
            @text_parts << text unless text.empty?
          when "tool_use"
            args = parse_tool_args(@current_args.to_s)
            @tool_calls << ToolCall.new(id: @current_block_id, name: @current_block_name, arguments: args)
          end
          @current_block_type = nil
        end

        def update_stop_reason(json : JSON::Any) : Nil
          if delta = hash_field(json, "delta")
            if reason = delta["stop_reason"]?.try(&.as_s?)
              @stop_reason = reason
            end
          end
          if u = hash_field(json, "usage")
            output = u["output_tokens"]?.try(&.as_i?) || 0
            @usage = TokenUsage.new(
              prompt_tokens: @usage.prompt_tokens,
              completion_tokens: output,
              total_tokens: @usage.prompt_tokens + output,
            )
          end
        end

        def record_error(msg : String) : Nil
          @error = true
          @text_parts << "Streaming error: #{msg}"
          @stop_reason = "error"
        end

        def to_response : Response
          finish = if @stop_reason == "tool_use"
                     "tool_calls"
                   elsif @error
                     "error"
                   else
                     "stop"
                   end
          Response.new(
            content: @text_parts.empty? ? nil : @text_parts.join("\n"),
            tool_calls: @tool_calls,
            finish_reason: finish,
            usage: @usage,
          )
        end

        private def parse_tool_args(raw : String) : Hash(String, JSON::Any)
          return {} of String => JSON::Any if raw.empty?
          JSON.parse(raw).as_h? || {} of String => JSON::Any
        rescue
          {} of String => JSON::Any
        end

        # Safely extract a nested hash field from JSON::Any.
        # Returns nil if the field is missing, null, or not a hash.
        private def hash_field(node : JSON::Any, key : String) : Hash(String, JSON::Any)?
          node[key]?.try(&.as_h?)
        end

        private def hash_field(node : Hash(String, JSON::Any)?, key : String) : Hash(String, JSON::Any)?
          return nil unless node
          node[key]?.try(&.as_h?)
        end
      end

      # -----------------------------------------------------------------
      # SSE helpers
      # -----------------------------------------------------------------
      private def read_sse_events(io : IO, &block : String ->) : Nil
        io.each_line do |line|
          line = line.strip
          next if line.empty? || line.starts_with?(':')

          if line.starts_with?(SSE_DATA_PREFIX)
            block.call(line.lchop(SSE_DATA_PREFIX))
          end
        end
      end

      private def build_streaming_response(
        content : String::Builder,
        tool_calls_map : Hash(Int32, {id: String, name: String, args: String::Builder}),
        finish_reason : String,
        usage : TokenUsage,
      ) : Response
        tool_calls = tool_calls_map.keys.sort!.compact_map do |idx|
          entry = tool_calls_map[idx]?
          next unless entry
          parsed_args = parse_json_args(entry[:args].to_s)
          ToolCall.new(id: entry[:id], name: entry[:name], arguments: parsed_args)
        end

        text = content.to_s
        Response.new(
          content: text.empty? ? nil : text,
          tool_calls: tool_calls,
          finish_reason: finish_reason,
          usage: usage,
        )
      end

      private def parse_json_args(raw : String) : Hash(String, JSON::Any)
        return {} of String => JSON::Any if raw.empty?
        JSON.parse(raw).as_h? || {} of String => JSON::Any
      rescue
        {} of String => JSON::Any
      end

      private def http_post_streaming(url : String, headers : HTTP::Headers, body : String, &block : IO -> Response) : Response
        uri = URI.parse(url)
        tls = uri.scheme == "https"

        host = uri.host
        raise "Invalid URL: missing host in '#{url}'" unless host

        client = HTTP::Client.new(host, port: uri.port, tls: tls)
        client.connect_timeout = CONNECT_TIMEOUT
        client.read_timeout = READ_TIMEOUT

        path = uri.request_target
        response : Response? = nil

        client.post(path, headers: headers, body: body) do |http_response|
          Log.debug { "Streaming response #{http_response.status_code}" }
          if http_response.status_code == 200
            response = block.call(http_response.body_io)
          else
            error_body = http_response.body_io.gets_to_end
            error_detail = extract_streaming_error(error_body, http_response.status_code)
            Log.error { "Streaming request failed: #{error_detail}" }
            response = Response.new(content: "Streaming error: #{error_detail}", finish_reason: "error")
          end
        end

        response || Response.new(content: "Streaming error: no response", finish_reason: "error")
      ensure
        client.try(&.close)
      end

      private def extract_streaming_error(body : String, status_code : Int32) : String
        json = JSON.parse(body)
        msg = json_hash(json, "error").try { |err| err["message"]?.try(&.as_s?) }
        msg ||= json["message"]?.try(&.as_s?)
        msg ? "HTTP #{status_code}: #{msg}" : "HTTP #{status_code}"
      rescue
        "HTTP #{status_code}"
      end

      # -----------------------------------------------------------------
      # Shared helpers
      # -----------------------------------------------------------------

      # Safely extract a nested JSON hash field. Returns nil if the field is
      # missing, null, or not a hash. Prevents "Expected Hash for #[]?" crashes
      # when JSON::Any wraps null instead of a hash.
      private def json_hash(node : JSON::Any?, key : String) : Hash(String, JSON::Any)?
        node.try { |parent| parent[key]?.try(&.as_h?) }
      end

      private def strip_provider_prefix(model : String) : String
        return model unless model.includes?("/")

        prefix = model.split("/", 2).first.downcase
        known = PROVIDERS.any? { |spec| spec.name == prefix }
        known ? model.split("/", 2).last : model
      end

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
