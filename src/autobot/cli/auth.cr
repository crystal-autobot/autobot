require "http/client"
require "http/server"
require "json"
require "log"
require "socket"
require "uri"
require "openssl"
require "base64"

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

      # Default Client ID and Secret (loaded from environment)
      def self.client_id : String
        ENV["GOOGLE_CLIENT_ID"]? || ENV["GEMINI_CLIENT_ID"]? || ""
      end

      def self.client_secret : String
        ENV["GOOGLE_CLIENT_SECRET"]? || ENV["GEMINI_CLIENT_SECRET"]? || ""
      end

      # Helper class to store authorization result
      private class AuthResult
        property auth_code : String? = nil
        property received_state : String? = nil
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
        puts "🔑 Gemini OAuth Authentication\n\n"

        port = find_available_port
        
        # Generate PKCE
        verifier = Random::Secure.hex(32)
        sha256 = OpenSSL::Digest.new("SHA256")
        sha256.update(verifier)
        challenge = Base64.urlsafe_encode(sha256.final, padding: false)

        state = Random::Secure.hex(16)
        
        # Use a channel to communicate the result from the server fiber
        result_chan = Channel(AuthResult).new

        server = HTTP::Server.new do |context|
          params = HTTP::Params.parse(URI.parse(context.request.resource).query || "")
          res = AuthResult.new
          res.auth_code = params["code"]?
          res.received_state = params["state"]?

          context.response.content_type = "text/html"
          if res.auth_code && res.received_state == state
            context.response.print "<h1>Authorization Successful!</h1><p>You can close this window and return to the terminal.</p><script>window.close();</script>"
            result_chan.send(res)
          else
            context.response.status_code = 400
            context.response.print "<h1>Authorization Failed</h1><p>Invalid state or missing code.</p>"
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
        puts "\e[1;34m#{auth_url}\e[0m\n\n"
        puts "Waiting for authorization on #{redirect_uri}..."

        spawn { server.listen }

        # Wait for result or timeout
        auth_code = nil
        select
        when result = result_chan.receive
          auth_code = result.auth_code
        when timeout(5.minutes)
          puts "\n❌ Authorization timed out."
        end

        # Small delay to let browser finish request, then close
        spawn { sleep 1.second; server.close } rescue nil

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

      private def self.find_available_port : Int32
        # Try 8085 first, then random
        [8085, 0].each do |p|
          begin
            s = TCPServer.new("127.0.0.1", p)
            actual_p = s.local_address.port
            s.close
            return actual_p
          rescue
            next
          end
        end
        8085 # Fallback
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
          "User-Agent"   => "google-api-nodejs-client/9.15.1",
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
