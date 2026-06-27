require "http/client"
require "http/server"
require "json"
require "log"
require "socket"
require "uri"
require "openssl"
require "base64"
require "colorize"

module Autobot
  module CLI
    module Auth
      Log = ::Log.for("cli.auth")

      OAUTH_AUTH_URL  = "https://accounts.google.com/o/oauth2/v2/auth"
      OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token"
      SCOPES          = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
      ]

      DEFAULT_CALLBACK_PORT   = 8085
      AUTH_TIMEOUT            = 5.minutes
      GOOGLE_OAUTH_USER_AGENT = "google-api-nodejs-client/9.15.1"

      SUCCESS_HTML = "<h1>Authorization successful</h1>" \
                     "<p>You can close this window and return to the terminal.</p>" \
                     "<script>window.close()</script>"
      FAILURE_HTML = "<h1>Authorization failed</h1><p>Invalid state or missing code.</p>"

      # Default Client ID and Secret (loaded from environment)
      def self.client_id : String
        ENV["GOOGLE_CLIENT_ID"]? || ENV["GEMINI_CLIENT_ID"]? || ""
      end

      def self.client_secret : String
        ENV["GOOGLE_CLIENT_SECRET"]? || ENV["GEMINI_CLIENT_SECRET"]? || ""
      end

      def self.run(config_path : String?, args : Array(String)) : Nil
        subcommand = args.shift?
        case subcommand
        when "gemini"
          authenticate_gemini(config_path)
        when nil
          puts "Usage: autobot auth <provider>"
          puts "Available providers: gemini"
        else
          puts "Unknown auth provider: #{subcommand}"
        end
      end

      private def self.authenticate_gemini(config_path : String?) : Nil
        puts "🔑 Gemini OAuth authentication\n\n"

        port = find_available_port

        # Generate PKCE
        verifier = Random::Secure.hex(32)
        sha256 = OpenSSL::Digest.new("SHA256")
        sha256.update(verifier)
        challenge = Base64.urlsafe_encode(sha256.final, padding: false)

        state = Random::Secure.hex(16)

        # Channel carries the authorization code back from the callback fiber
        result_chan = Channel(String).new

        server = HTTP::Server.new do |context|
          params = HTTP::Params.parse(URI.parse(context.request.resource).query || "")
          context.response.content_type = "text/html"

          code = params["code"]?
          if code && params["state"]? == state
            context.response.print SUCCESS_HTML
            flush_response(context.response) # deliver the page before the server is torn down
            result_chan.send(code)
          else
            context.response.status = HTTP::Status::BAD_REQUEST
            context.response.print FAILURE_HTML
          end
        end

        address = server.bind_tcp "127.0.0.1", port
        actual_port = address.port
        redirect_uri = "http://localhost:#{actual_port}/oauth2callback"
        cid = client_id
        if cid.empty?
          raise "Google Client ID is missing. Please set GOOGLE_CLIENT_ID or GEMINI_CLIENT_ID in your environment."
        end
        auth_url = build_auth_url(cid, redirect_uri, SCOPES.join("%20"), state, challenge)

        puts "Please visit this URL to authorize Autobot:\n\n"
        puts "#{auth_url.colorize.blue.bold}\n\n"
        puts "Waiting for authorization on #{redirect_uri}..."

        spawn { server.listen }

        # Wait for result or timeout
        auth_code = select
        when received = result_chan.receive
          received
        when timeout(AUTH_TIMEOUT)
          puts "\n❌ Authorization timed out."
          nil
        end

        close_callback_server(server)

        if auth_code
          puts "✓ Received authorization code. Exchanging for tokens..."
          sec = client_secret
          if sec.empty?
            raise "Google Client Secret is missing. Please set GOOGLE_CLIENT_SECRET or GEMINI_CLIENT_SECRET in your environment."
          end
          exchange_code_for_tokens(config_path, cid, sec, auth_code, verifier, redirect_uri)
        else
          puts "❌ Authorization failed."
        end
      end

      private def self.build_auth_url(client_id, redirect_uri, scopes, state, challenge)
        "#{OAUTH_AUTH_URL}?client_id=#{client_id}&redirect_uri=#{URI.encode_www_form(redirect_uri)}&response_type=code&scope=#{scopes}&state=#{state}&code_challenge=#{challenge}&code_challenge_method=S256&access_type=offline&prompt=consent"
      end

      # Best-effort: push the response to the browser before we signal success.
      # If the browser already disconnected, ignore it — the code still matters.
      private def self.flush_response(response : HTTP::Server::Response) : Nil
        response.close
      rescue ex
        Log.debug { "OAuth callback response flush failed: #{ex.message}" }
      end

      private def self.close_callback_server(server : HTTP::Server) : Nil
        server.close
      rescue ex
        Log.debug { "Error closing OAuth callback server: #{ex.message}" }
      end

      private def self.find_available_port : Int32
        # Try the preferred port first, then let the OS pick a free one
        [DEFAULT_CALLBACK_PORT, 0].each do |port|
          begin
            server = TCPServer.new("127.0.0.1", port)
            available_port = server.local_address.port
            server.close
            return available_port
          rescue
            next
          end
        end
        DEFAULT_CALLBACK_PORT
      end

      private def self.exchange_code_for_tokens(config_path : String?, client_id : String, client_secret : String, code : String, verifier : String, redirect_uri : String) : Nil
        params = {
          "client_id"     => client_id,
          "client_secret" => client_secret,
          "code"          => code,
          "grant_type"    => "authorization_code",
          "redirect_uri"  => redirect_uri,
          "code_verifier" => verifier,
        }

        headers = HTTP::Headers{
          "Content-Type" => "application/x-www-form-urlencoded",
          "User-Agent"   => GOOGLE_OAUTH_USER_AGENT,
        }

        response = HTTP::Client.post(OAUTH_TOKEN_URL, headers: headers, form: params)

        if response.success?
          data = JSON.parse(response.body)
          refresh_token = data["refresh_token"]?

          if refresh_token
            save_oauth_config(config_path, client_id, client_secret, refresh_token.as_s)
            puts "\n✅ Gemini OAuth configured successfully!"
            puts "The refresh token has been saved to your config file."
          else
            puts "\n❌ Error: No refresh token received."
            puts "If you already authorized, go to Google Account > Security > Third-party apps and remove Autobot/Gemini CLI, then try again."
            puts "Response: #{response.body}"
          end
        else
          puts "\n❌ Error exchanging code for tokens: #{response.status_code}"
          puts response.body
        end
      end

      private def self.save_oauth_config(config_path : String?, client_id : String, client_secret : String, refresh_token : String) : Nil
        config = Config::Loader.load(config_path, validate: false)
        providers = config.providers ||= Config::ProvidersConfig.new
        gemini = providers.gemini ||= Config::ProviderConfig.new

        gemini.client_id = client_id
        gemini.client_secret = client_secret
        gemini.refresh_token = refresh_token

        Config::Loader.save(config, config_path)
      end
    end
  end
end
