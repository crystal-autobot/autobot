require "http/client"
require "json"
require "log"
require "./provider"

module Autobot
  module Providers
    # Google Gemini provider - https://ai.google.dev/gemini-api/docs
    # Supports both standard Google AI Studio (API Key) and Code Assist API (OAuth)
    # Includes Context Caching support for large context payloads
    class GeminiProvider < Provider
      Log = ::Log.for(self)

      # Standard API for API Keys
      AI_STUDIO_BASE = "https://generativelanguage.googleapis.com/v1beta"
      # Code Assist API for OAuth
      CODE_ASSIST_BASE = "https://cloudcode-pa.googleapis.com/v1internal"

      DEFAULT_MODEL       = "gemini/gemini-2.0-flash"
      OAUTH_TOKEN_URL     = "https://oauth2.googleapis.com/token"
      TOKEN_EXPIRY_LEEWAY = 60 # seconds

      # Client ID and Secret loaded from environment

      CONNECT_TIMEOUT = 30.seconds
      READ_TIMEOUT    = 300.seconds
      USER_AGENT      = "Autobot/#{VERSION}"

      @client_id : String?
      @client_secret : String?
      @refresh_token : String?
      @access_token : String?
      @token_expiry : Time?
      @token_mutex : Mutex = Mutex.new
      @project_id : String?

      @cached_name : String? = nil
      @cached_hash : UInt64 = 0_u64

      def initialize(
        api_key : String,
        @model : String = DEFAULT_MODEL,
        client_id : String? = nil,
        client_secret : String? = nil,
        refresh_token : String? = nil,
        api_base : String? = nil,
      )
        super(api_key, api_base)
        @client_id = client_id.presence || ENV["GOOGLE_CLIENT_ID"]? || ENV["GEMINI_CLIENT_ID"]?
        @client_secret = client_secret.presence || ENV["GOOGLE_CLIENT_SECRET"]? || ENV["GEMINI_CLIENT_SECRET"]?
        @refresh_token = refresh_token
      end

      def default_model : String
        @model
      end

      def supports_progressive_disclosure? : Bool
        false
      end

      private def use_oauth? : Bool
        !@refresh_token.nil? && !@refresh_token.try(&.empty?)
      end

      # Get valid access token, refreshing if necessary
      private def get_access_token : String
        @token_mutex.synchronize do
          # Use API key if no OAuth config
          return @api_key unless use_oauth?

          # Check if we have a valid token
          if (token = @access_token) && (expiry = @token_expiry) && expiry > Time.local + TOKEN_EXPIRY_LEEWAY.seconds
            return token
          end

          # Need to refresh token
          refresh_access_token
        end
      end

      private def refresh_access_token : String
        client_id = @client_id
        client_secret = @client_secret
        refresh_token = @refresh_token

        if client_id.nil? || client_id.empty? || client_secret.nil? || client_secret.empty? || refresh_token.nil? || refresh_token.empty?
          raise "OAuth configuration missing for Gemini (client_id, client_secret, or refresh_token)"
        end

        Log.info { "Refreshing Gemini OAuth token..." }

        params = {
          "client_id"     => client_id,
          "client_secret" => client_secret,
          "refresh_token" => refresh_token,
          "grant_type"    => "refresh_token",
        }

        response = HTTP::Client.post(OAUTH_TOKEN_URL, form: params)

        if response.success?
          data = JSON.parse(response.body)
          new_token = data["access_token"].as_s
          expires_in = data["expires_in"].as_i

          @access_token = new_token
          @token_expiry = Time.local + expires_in.seconds

          Log.info { "Token refreshed successfully. Expires in #{expires_in}s" }

          # Invalidate project ID when token is refreshed
          @project_id = nil

          new_token
        else
          Log.error { "Failed to refresh token: #{response.status_code} - #{response.body}" }
          raise "Failed to refresh Gemini OAuth token: #{response.body}"
        end
      end

      private def build_headers : HTTP::Headers
        headers = HTTP::Headers{
          "Content-Type" => "application/json",
          "User-Agent"   => USER_AGENT,
        }

        if use_oauth?
          token = get_access_token
          headers["Authorization"] = "Bearer #{token}"
          # Strict headers required by Code Assist API
          headers["User-Agent"] = "google-api-nodejs-client/9.15.1"
          headers["X-Goog-Api-Client"] = "gl-node/22.13.1"
          headers["Client-Metadata"] = {
            "ideType"    => "ANTIGRAVITY",
            "platform"   => "PLATFORM_UNSPECIFIED",
            "pluginType" => "GEMINI",
          }.to_json
        end

        headers
      end

      private def ensure_project_id(headers : HTTP::Headers) : String
        if pid = @project_id
          return pid
        end

        Log.info { "Detecting authorized project ID..." }

        # Call loadCodeAssist to find the project ID
        url = "#{CODE_ASSIST_BASE}:loadCodeAssist"
        payload = {
          "cloudaicompanionProject" => nil,
          "metadata"                => {
            "ideType"     => "IDE_UNSPECIFIED",
            "platform"    => "PLATFORM_UNSPECIFIED",
            "pluginType"  => "GEMINI",
            "duetProject" => nil,
          },
        }.to_json

        response = HTTP::Client.post(url, headers: headers, body: payload)
        if response.success?
          json = JSON.parse(response.body)
          if proj = json["cloudaicompanionProject"]?
            pid = proj.as_s
            @project_id = pid
            Log.info { "Detected project ID: #{pid}" }
            return pid
          end
        end

        Log.warn { "Could not detect project ID, falling back to 'autobot'" }
        @project_id = "autobot"
        "autobot"
      end

      def chat(
        messages : Array(Hash(String, JSON::Any)),
        tools : Array(Hash(String, JSON::Any))? = nil,
        model : String? = nil,
        max_tokens : Int32 = DEFAULT_MAX_TOKENS,
        temperature : Float64 = DEFAULT_TEMPERATURE,
      ) : Response
        max_retries = 3
        base_delay = 2.0

        effective_model = (model || @model).sub(/^gemini\//, "")
        bare_model = effective_model.includes?("/") ? effective_model.split("/", 2).last : effective_model
        model_path = "models/#{bare_model}"

        max_retries.times do |attempt|
          headers = build_headers

          begin
            if use_oauth?
              project_id = ensure_project_id(headers)
              url = "#{CODE_ASSIST_BASE}:generateContent"
              body = build_code_assist_payload(messages, tools, bare_model, project_id)
              response = HTTP::Client.post(url, headers: headers, body: body)
              if response.success?
                return parse_native_response(response.body)
              end
              handle_error_response(response, attempt, max_retries, base_delay)
            else
              # Use AI Studio native generateContent endpoint supporting caching
              response = do_generate_content_with_cache_check(model_path, messages, tools, max_tokens, temperature)
              return response
            end
          rescue ex
            if attempt == max_retries - 1
              raise ex
            end
            delay = base_delay * (2 ** attempt) + (rand * 0.5)
            Log.warn { "Error during chat call: #{ex.message}, retrying in #{delay.round(2)}s (attempt #{attempt + 1}/#{max_retries})" }
            sleep delay.seconds
          end
        end

        raise "Max retries exceeded"
      end

      private def do_generate_content_with_cache_check(
        model_path : String,
        messages : Array(Hash(String, JSON::Any)),
        tools : Array(Hash(String, JSON::Any))?,
        max_tokens : Int32,
        temperature : Float64,
      ) : Response
        system_text = extract_system_prompt_text(messages)
        user_history = reject_system_messages(messages)
        contents = map_messages_to_native(user_history)
        gemini_tools = map_tools_to_native(tools)

        cache_content_str = system_text + (tools ? tools.to_json : "")
        current_hash = cache_content_str.hash

        if @cached_hash != current_hash
          @cached_name = nil
        end

        if name = @cached_name
          response = do_generate_content_cached(model_path, name, contents, max_tokens, temperature)
          unless response.error? && (response.content || "").includes?("404")
            return response
          end
          Log.warn { "Cache #{name} expired or not found, recreating..." }
          @cached_name = nil
        end

        if cache_content_str.size > 8000
          @cached_name = create_cache(model_path, system_text, gemini_tools)
          if name = @cached_name
            @cached_hash = current_hash
            return do_generate_content_cached(model_path, name, contents, max_tokens, temperature)
          end
        end

        do_generate_content_native(model_path, system_text, gemini_tools, contents, max_tokens, temperature)
      end

      private def create_cache(model_path : String, system_text : String, tools : Array(JSON::Any)?) : String?
        api_base = @api_base || AI_STUDIO_BASE
        url = "#{api_base}/cachedContents?key=#{@api_key}"

        body = {
          "model" => JSON::Any.new(model_path),
          "ttl"   => JSON::Any.new("3600s"),
        } of String => JSON::Any

        unless system_text.empty?
          body["systemInstruction"] = JSON::Any.new({
            "parts" => JSON::Any.new([
              JSON::Any.new({"text" => JSON::Any.new(system_text)} of String => JSON::Any),
            ] of JSON::Any),
          } of String => JSON::Any)
        end

        if tools && !tools.empty?
          body["tools"] = JSON::Any.new(tools)
        end

        headers = HTTP::Headers{"Content-Type" => "application/json", "User-Agent" => USER_AGENT}
        response = http_post(url, headers, body.to_json)

        if response.success?
          json = JSON.parse(response.body)
          name = json["name"]?.try(&.as_s?)
          Log.info { "Created explicit Gemini cache: #{name}" }
          name
        else
          Log.debug { "Failed to create cache (might be under min tokens): #{response.body}" }
          nil
        end
      end

      private def do_generate_content_cached(
        model_path : String,
        cached_name : String,
        contents : Array(Hash(String, JSON::Any)),
        max_tokens : Int32,
        temperature : Float64,
      ) : Response
        api_base = @api_base || AI_STUDIO_BASE
        url = "#{api_base}/#{model_path}:generateContent?key=#{@api_key}"

        body = {
          "cachedContent"    => JSON::Any.new(cached_name),
          "contents"         => JSON::Any.new(contents.map { |c| JSON::Any.new(c) }),
          "generationConfig" => JSON::Any.new({
            "maxOutputTokens" => JSON::Any.new(max_tokens.to_i64),
            "temperature"     => JSON::Any.new(temperature),
          } of String => JSON::Any),
        } of String => JSON::Any

        headers = HTTP::Headers{"Content-Type" => "application/json", "User-Agent" => USER_AGENT}
        response = http_post(url, headers, body.to_json)
        parse_native_response(response.body)
      end

      private def do_generate_content_native(
        model_path : String,
        system_text : String,
        tools : Array(Hash(String, JSON::Any))?,
        contents : Array(Hash(String, JSON::Any)),
        max_tokens : Int32,
        temperature : Float64,
      ) : Response
        api_base = @api_base || AI_STUDIO_BASE
        url = "#{api_base}/#{model_path}:generateContent?key=#{@api_key}"

        body = {
          "contents"         => JSON::Any.new(contents.map { |c| JSON::Any.new(c) }),
          "generationConfig" => JSON::Any.new({
            "maxOutputTokens" => JSON::Any.new(max_tokens.to_i64),
            "temperature"     => JSON::Any.new(temperature),
          } of String => JSON::Any),
        } of String => JSON::Any

        unless system_text.empty?
          body["systemInstruction"] = JSON::Any.new({
            "parts" => JSON::Any.new([
              JSON::Any.new({"text" => JSON::Any.new(system_text)} of String => JSON::Any),
            ] of JSON::Any),
          } of String => JSON::Any)
        end

        if tools && !tools.empty?
          body["tools"] = JSON::Any.new(tools.map { |t| JSON::Any.new(t) })
        end

        headers = HTTP::Headers{"Content-Type" => "application/json", "User-Agent" => USER_AGENT}
        response = http_post(url, headers, body.to_json)
        parse_native_response(response.body)
      end

      private def handle_error_response(response, attempt, max_retries, base_delay)
        status = response.status_code

        # If we get a 401 Unauthorized, our token might have expired despite our check
        if status == 401 && use_oauth?
          Log.warn { "401 Unauthorized with OAuth token, forcing refresh..." }
          @token_expiry = nil
          return
        end

        if (status == 429 || status >= 500) && attempt < max_retries - 1
          delay = base_delay * (2 ** attempt) + (rand * 0.5)
          Log.warn { "Rate limited or server error (#{status}), retrying in #{delay.round(2)}s (attempt #{attempt + 1}/#{max_retries})" }
          sleep delay.seconds
          return
        end

        raise "Gemini API request failed: #{status} - #{response.body}"
      end

      private def build_code_assist_payload(messages, tools, model, project_id) : String
        contents = map_messages_to_native(messages)
        system_instr = extract_system_instruction(messages)
        native_tools = map_tools_to_native(tools)

        inner = {
          "contents"          => JSON::Any.new(contents.map { |content_msg| JSON::Any.new(content_msg) }),
          "systemInstruction" => system_instr ? JSON::Any.new(system_instr) : nil,
          "tools"             => native_tools ? JSON::Any.new(native_tools.map { |tool| JSON::Any.new(tool) }) : nil,
        }.compact

        {
          "model"          => JSON::Any.new(model),
          "project"        => JSON::Any.new(project_id),
          "user_prompt_id" => JSON::Any.new("autobot-#{Time.local.to_unix}"),
          "request"        => JSON::Any.new(inner.transform_values { |val| val }),
        }.to_json
      end

      private def build_native_payload(messages, tools, max_tokens, temperature) : String
        contents = map_messages_to_native(messages)
        system_instr = extract_system_instruction(messages)
        native_tools = map_tools_to_native(tools)

        payload = {
          "contents"          => JSON::Any.new(contents.map { |content_msg| JSON::Any.new(content_msg) }),
          "systemInstruction" => system_instr ? JSON::Any.new(system_instr) : nil,
          "tools"             => native_tools ? JSON::Any.new(native_tools.map { |tool| JSON::Any.new(tool) }) : nil,
          "generationConfig"  => JSON::Any.new({
            "temperature"     => JSON::Any.new(temperature),
            "maxOutputTokens" => JSON::Any.new(max_tokens.to_i64),
          } of String => JSON::Any),
        }.compact

        payload.to_json
      end

      private def map_messages_to_native(messages) : Array(Hash(String, JSON::Any))
        contents = [] of Hash(String, JSON::Any)
        messages.each do |msg|
          role = msg["role"].as_s
          next if role == "system"

          role = "model" if role == "assistant"
          role = "function" if role == "tool"

          parts = build_native_parts(msg, role)
          contents << {
            "role"  => JSON::Any.new(role),
            "parts" => JSON::Any.new(parts.map { |part| JSON::Any.new(part) }),
          } unless parts.empty?
        end
        contents
      end

      private def build_native_parts(msg, role) : Array(Hash(String, JSON::Any))
        parts = [] of Hash(String, JSON::Any)

        has_thought_parts = false
        if role == "model" && (tcalls = msg["tool_calls"]?.try(&.as_a?))
          if tparts = extract_thought_parts(tcalls)
            parts.concat(tparts)
            has_thought_parts = true
          end
        end

        if !has_thought_parts
          if text = msg["content"]?.try(&.as_s?)
            parts << {"text" => JSON::Any.new(text)}
          end
        end

        if role == "model" && (tcalls = msg["tool_calls"]?.try(&.as_a?))
          append_native_tool_calls(parts, tcalls)
        end

        if role == "function"
          append_native_tool_result(parts, msg)
        end

        parts
      end

      private def extract_thought_parts(tcalls) : Array(Hash(String, JSON::Any))?
        tcalls.each do |tcall|
          if extra = tcall["extra_content"]?
            if thought_parts = extra["thought_parts"]?.try(&.as_a?)
              res = [] of Hash(String, JSON::Any)
              thought_parts.each do |tpart|
                if tp_h = tpart.as_h?
                  res << tp_h.transform_values { |val| val }
                end
              end
              return res
            end
          end
        end
        nil
      end

      private def append_native_tool_calls(parts, tcalls)
        tcalls.each do |tcall|
          func = tcall["function"]
          thought_sig = tcall["thought_signature"]?.try(&.as_s?)
          part_payload = {
            "functionCall" => JSON::Any.new({
              "name" => func["name"],
              "args" => parse_json_or_wrap(func["arguments"]?),
            } of String => JSON::Any),
          } of String => JSON::Any
          if thought_sig
            part_payload["thoughtSignature"] = JSON::Any.new(thought_sig)
          end
          parts << part_payload
        end
      end

      private def append_native_tool_result(parts, msg)
        name = msg["name"]?.try(&.as_s?) || "unknown"
        result = parse_json_or_wrap(msg["content"]?)
        parts << {
          "functionResponse" => JSON::Any.new({
            "name"     => JSON::Any.new(name),
            "response" => result,
          } of String => JSON::Any),
        }
      end

      private def extract_system_instruction(messages) : Hash(String, JSON::Any)?
        if sys_msg = messages.find { |msg| msg["role"].as_s == "system" }
          return {
            "role"  => JSON::Any.new("user"),
            "parts" => JSON::Any.new([JSON::Any.new({"text" => JSON::Any.new(sys_msg["content"].as_s)})]),
          }
        end
        nil
      end

      private def extract_system_prompt_text(messages : Array(Hash(String, JSON::Any))) : String
        messages
          .select { |message| message["role"]?.try(&.as_s?) == "system" }
          .compact_map { |message| message["content"]?.try(&.as_s?) }
          .join("\n\n")
      end

      private def reject_system_messages(messages : Array(Hash(String, JSON::Any))) : Array(Hash(String, JSON::Any))
        messages.reject { |message| message["role"]?.try(&.as_s?) == "system" }
      end

      private def map_tools_to_native(tools) : Array(Hash(String, JSON::Any))?
        return nil if tools.nil? || tools.empty?

        decls = tools.compact_map do |tool|
          func = tool["function"]?
          next unless func
          {
            "name"        => func["name"],
            "description" => func["description"]? || JSON::Any.new("No description available"),
            "parameters"  => func["parameters"]? || JSON::Any.new({"type" => JSON::Any.new("object"), "properties" => JSON::Any.new({} of String => JSON::Any)}),
          } of String => JSON::Any
        end

        [{"functionDeclarations" => JSON::Any.new(decls.map { |decl| JSON::Any.new(decl) })}]
      end

      # ameba:disable Metrics/CyclomaticComplexity
      private def parse_native_response(body : String) : Response
        json = JSON.parse(body)
        # Handle both wrapped and unwrapped response
        res = json["response"]? || json

        if (candidates = res["candidates"]?) && (first = candidates[0]?)
          content = nil
          native_parts = [] of JSON::Any
          thought_parts = [] of JSON::Any

          if parts = first["content"]?.try(&.["parts"]?.try(&.as_a?))
            text_parts = parts.compact_map(&.["text"]?.try(&.as_s?))
            content = text_parts.join("\n") unless text_parts.empty?

            # Save all parts for preservation (including thought/thought_signature)
            parts.each do |part|
              native_parts << part
              unless part["functionCall"]?
                thought_parts << part
              end
            end
          end

          extra = if !thought_parts.empty?
                    JSON::Any.new({
                      "thought_parts" => JSON::Any.new(thought_parts),
                    } of String => JSON::Any)
                  else
                    nil
                  end

          tool_calls = [] of ToolCall
          if parts
            parts.each do |part|
              if fcall = part["functionCall"]?
                name = fcall["name"].as_s
                args = fcall["args"]?.try(&.as_h) || {} of String => JSON::Any
                thought_sig = part["thoughtSignature"]?.try(&.as_s?)
                tool_calls << ToolCall.new(
                  id: "call_#{Random::Secure.hex(8)}",
                  name: name,
                  arguments: args,
                  extra_content: extra,
                  thought_signature: thought_sig
                )
              end
            end
          end

          usage_meta = res["usageMetadata"]?
          usage = parse_native_usage(usage_meta)

          return Response.new(
            content: content,
            tool_calls: tool_calls,
            usage: usage,
            native_parts: native_parts
          )
        end

        Response.new(content: "Error: No candidates in response", finish_reason: "error")
      end

      private def parse_native_usage(node : JSON::Any?) : TokenUsage
        return TokenUsage.new unless node
        TokenUsage.new(
          prompt_tokens: node["promptTokenCount"]?.try(&.as_i) || 0,
          completion_tokens: node["candidatesTokenCount"]?.try(&.as_i) || 0,
          total_tokens: node["totalTokenCount"]?.try(&.as_i) || 0,
          cache_creation_tokens: 0,
          cache_read_tokens: node["cachedContentTokenCount"]?.try(&.as_i) || 0
        )
      end

      private def parse_usage(node : JSON::Any?) : TokenUsage
        return TokenUsage.new unless node
        TokenUsage.new(
          prompt_tokens: node["prompt_tokens"]?.try(&.as_i?) || 0,
          completion_tokens: node["completion_tokens"]?.try(&.as_i?) || 0,
          total_tokens: node["total_tokens"]?.try(&.as_i?) || 0
        )
      end

      private def parse_json_or_wrap(node : JSON::Any?) : JSON::Any
        return JSON::Any.new({"result" => JSON::Any.new("")}) unless node
        str = node.as_s?
        return node unless str

        begin
          json = JSON.parse(str)
          json.as_h? ? json : JSON::Any.new({"result" => json})
        rescue
          JSON::Any.new({"result" => node})
        end
      end

      private def http_post(url : String, headers : HTTP::Headers, body : String) : HTTP::Client::Response
        uri = URI.parse(url)
        tls = uri.scheme == "https"
        host = uri.host || "generativelanguage.googleapis.com"
        client = HTTP::Client.new(host, port: uri.port, tls: tls)
        client.connect_timeout = CONNECT_TIMEOUT
        client.read_timeout = READ_TIMEOUT
        client.post(uri.request_target, headers: headers, body: body)
      ensure
        client.try(&.close)
      end
    end
  end
end
