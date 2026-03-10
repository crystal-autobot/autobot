require "http/client"
require "json"
require "log"
require "./provider"

module Autobot
  module Providers
    # Google Gemini provider - https://ai.google.dev/gemini-api/docs
    # Supports both standard Google AI Studio (API Key) and Code Assist API (OAuth)
    class GeminiProvider < Provider
      Log = ::Log.for(self)

      # Standard API for API Keys
      AI_STUDIO_BASE = "https://generativelanguage.googleapis.com/v1beta/openai"
      # Code Assist API for OAuth
      CODE_ASSIST_BASE = "https://cloudcode-pa.googleapis.com/v1internal"

      DEFAULT_MODEL       = "gemini/gemini-2.0-flash"
      OAUTH_TOKEN_URL     = "https://oauth2.googleapis.com/token"
      TOKEN_EXPIRY_LEEWAY = 60 # seconds

      # Client ID and Secret loaded from environment

      @client_id : String?
      @client_secret : String?
      @refresh_token : String?
      @access_token : String?
      @token_expiry : Time?
      @token_mutex : Mutex = Mutex.new
      @project_id : String?

      def initialize(
        api_key : String,
        @model : String = DEFAULT_MODEL,
        client_id : String? = nil,
        client_secret : String? = nil,
        refresh_token : String? = nil,
        api_base : String? = nil
      )
        super(api_key, api_base)
        @client_id = client_id.presence || ENV["GOOGLE_CLIENT_ID"]? || ENV["GEMINI_CLIENT_ID"]?
        @client_secret = client_secret.presence || ENV["GOOGLE_CLIENT_SECRET"]? || ENV["GEMINI_CLIENT_SECRET"]?
        @refresh_token = refresh_token
      end

      def default_model : String
        @model
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
        token = get_access_token
        headers = HTTP::Headers{
          "Content-Type"  => "application/json",
          "Authorization" => "Bearer #{token}",
        }

        if use_oauth?
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

        effective_model = model || @model
        # Strip provider prefix if present (e.g. "gemini/gemini-pro" -> "gemini-pro")
        bare_model = effective_model.includes?("/") ? effective_model.split("/", 2).last : effective_model

        max_retries.times do |attempt|
          headers = build_headers

          if use_oauth?
            project_id = ensure_project_id(headers)
            url = "#{CODE_ASSIST_BASE}:generateContent"
            body = build_code_assist_payload(messages, tools, bare_model, project_id)
          else
            # AI Studio OpenAI-compatible endpoint
            url = "#{@api_base || AI_STUDIO_BASE}/chat/completions"
            body = build_openai_body(messages, tools, bare_model, max_tokens, temperature)
          end

          response = HTTP::Client.post(url, headers: headers, body: body)

          if response.success?
            return use_oauth? ? parse_native_response(response.body) : parse_openai_response(response.body)
          end

          handle_error_response(response, attempt, max_retries, base_delay)
        end

        raise "Max retries exceeded"
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

      private def build_openai_body(messages, tools, model, max_tokens, temperature)
        {
          "model"       => JSON::Any.new(model),
          "messages"    => JSON::Any.new(messages.map { |m| JSON::Any.new(m.transform_values { |v| v }) }),
          "max_tokens"  => JSON::Any.new(max_tokens.to_i64),
          "temperature" => JSON::Any.new(temperature),
          "tools"       => tools ? JSON::Any.new(tools.map { |t| JSON::Any.new(t.transform_values { |v| v }) }) : nil,
          "tool_choice" => tools ? JSON::Any.new("auto") : nil,
        }.compact.to_json
      end

      private def parse_openai_response(body : String) : Response
        json = JSON.parse(body)
        choice = json["choices"][0]
        message = choice["message"]

        content = message["content"]?.try(&.as_s?)
        tool_calls = parse_openai_tool_calls(message["tool_calls"]?)
        usage = parse_usage(json["usage"]?)

        Response.new(
          content: content,
          tool_calls: tool_calls,
          usage: usage
        )
      end

      private def parse_openai_tool_calls(node : JSON::Any?) : Array(ToolCall)
        return [] of ToolCall unless arr = node.try(&.as_a?)
        arr.compact_map do |tc|
          func = tc["function"]?
          next unless func
          args_str = func["arguments"].as_s
          args = JSON.parse(args_str).as_h
          ToolCall.new(
            id: tc["id"].as_s,
            name: func["name"].as_s,
            arguments: args
          )
        end
      end

      private def build_code_assist_payload(messages, tools, model, project_id) : String
        contents = map_messages_to_native(messages)
        system_instr = extract_system_instruction(messages)
        native_tools = map_tools_to_native(tools)

        inner = {
          "contents"          => JSON::Any.new(contents.map { |c| JSON::Any.new(c) }),
          "systemInstruction" => system_instr ? JSON::Any.new(system_instr) : nil,
          "tools"             => native_tools ? JSON::Any.new(native_tools.map { |t| JSON::Any.new(t) }) : nil,
        }.compact

        {
          "model"          => JSON::Any.new(model),
          "project"        => JSON::Any.new(project_id),
          "user_prompt_id" => JSON::Any.new("autobot-#{Time.local.to_unix}"),
          "request"        => JSON::Any.new(inner.transform_values { |v| v }),
        }.to_json
      end

      private def map_messages_to_native(messages) : Array(Hash(String, JSON::Any))
        contents = [] of Hash(String, JSON::Any)
        messages.each do |msg|
          role = msg["role"].as_s
          next if role == "system"

          role = "model" if role == "assistant"
          role = "function" if role == "tool"

          parts = [] of Hash(String, JSON::Any)
          if text = msg["content"]?.try(&.as_s?)
            parts << {"text" => JSON::Any.new(text)}
          end

          # Handle tool calls in assistant messages
          if role == "model" && (tcalls = msg["tool_calls"]?.try(&.as_a?))
            tcalls.each do |tc|
              func = tc["function"]
              parts << {
                "functionCall" => JSON::Any.new({
                  "name" => func["name"],
                  "args" => parse_json_or_wrap(func["arguments"]?),
                } of String => JSON::Any),
              }
            end
          end

          # Handle tool results
          if role == "function"
            name = msg["name"]?.try(&.as_s?) || "unknown"
            result = parse_json_or_wrap(msg["content"]?)
            parts << {
              "functionResponse" => JSON::Any.new({
                "name"     => JSON::Any.new(name),
                "response" => result,
              } of String => JSON::Any),
            }
          end

          contents << {
            "role"  => JSON::Any.new(role),
            "parts" => JSON::Any.new(parts.map { |p| JSON::Any.new(p) }),
          } unless parts.empty?
        end
        contents
      end

      private def extract_system_instruction(messages) : Hash(String, JSON::Any)?
        if sys_msg = messages.find { |m| m["role"].as_s == "system" }
          return {
            "role"  => JSON::Any.new("user"),
            "parts" => JSON::Any.new([JSON::Any.new({"text" => JSON::Any.new(sys_msg["content"].as_s)})]),
          }
        end
        nil
      end

      private def map_tools_to_native(tools) : Array(Hash(String, JSON::Any))?
        return nil if tools.nil? || tools.empty?

        decls = tools.compact_map do |t|
          func = t["function"]?
          next unless func
          {
            "name"        => func["name"],
            "description" => func["description"]? || JSON::Any.new("No description available"),
            "parameters"  => func["parameters"]? || JSON::Any.new({ "type" => JSON::Any.new("object"), "properties" => JSON::Any.new({} of String => JSON::Any) }),
          } of String => JSON::Any
        end

        [{"functionDeclarations" => JSON::Any.new(decls.map { |d| JSON::Any.new(d) })}]
      end

      private def parse_native_response(body : String) : Response
        json = JSON.parse(body)
        # Handle both wrapped and unwrapped response
        res = json["response"]? || json

        if (candidates = res["candidates"]?) && (first = candidates[0]?)
          content = nil
          native_parts = [] of JSON::Any
          if (parts = first["content"]?.try(&.["parts"]?.try(&.as_a?)))
            text_parts = parts.compact_map(&.["text"]?.try(&.as_s?))
            content = text_parts.join("\n") unless text_parts.empty?
            
            # Save all parts for preservation (including thought/thought_signature)
            parts.each { |p| native_parts << p }
          end

          tool_calls = [] of ToolCall
          if parts
            parts.each do |part|
              if fcall = part["functionCall"]?
                name = fcall["name"].as_s
                args = fcall["args"]?.try(&.as_h) || {} of String => JSON::Any
                tool_calls << ToolCall.new(
                  id: "call_#{Random::Secure.hex(8)}",
                  name: name,
                  arguments: args
                )
              end
            end
          end

          usage = parse_native_usage(res["usageMetadata"]?)

          return Response.new(
            content: content,
            tool_calls: tool_calls,
            usage: usage
          )
        end

        Response.new(content: "Error: No candidates in response", finish_reason: "error")
      end

      private def parse_native_usage(node : JSON::Any?) : TokenUsage
        return TokenUsage.new unless node
        TokenUsage.new(
          prompt_tokens: node["promptTokenCount"]?.try(&.as_i) || 0,
          completion_tokens: node["candidatesTokenCount"]?.try(&.as_i) || 0,
          total_tokens: node["totalTokenCount"]?.try(&.as_i) || 0
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
    end
  end
end
