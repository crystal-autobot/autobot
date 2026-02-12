require "http/client"
require "json"
require "log"
require "uri"

module Autobot
  module Tools
    USER_AGENT      = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7_2) AppleWebKit/537.36"
    MAX_REDIRECTS   = 5
    DEFAULT_TIMEOUT = 10.seconds

    # Search the web using Brave Search API.
    class WebSearchTool < Tool
      Log = ::Log.for(self)

      DEFAULT_MAX_RESULTS = 5

      def initialize(
        @api_key : String? = nil,
        @max_results : Int32 = DEFAULT_MAX_RESULTS,
      )
        @api_key ||= ENV["BRAVE_API_KEY"]?
      end

      def name : String
        "web_search"
      end

      def description : String
        "Search the web. Returns titles, URLs, and snippets."
      end

      def parameters : ToolSchema
        ToolSchema.new(
          properties: {
            "query" => PropertySchema.new(type: "string", description: "Search query"),
            "count" => PropertySchema.new(type: "integer", description: "Number of results (1-10)", minimum: 1_i64, maximum: 10_i64),
          },
          required: ["query"]
        )
      end

      def execute(params : Hash(String, JSON::Any)) : String
        api_key = @api_key
        if api_key.nil? || api_key.empty?
          return "Error: BRAVE_API_KEY not configured"
        end

        query = params["query"].as_s
        count = Math.min(Math.max(params["count"]?.try(&.as_i) || @max_results, 1), 10)

        Log.info { "Web search: #{query} (count: #{count})" }

        uri = URI.parse("https://api.search.brave.com/res/v1/web/search")
        uri.query = URI::Params.encode({"q" => query, "count" => count.to_s})

        headers = HTTP::Headers{
          "Accept"               => "application/json",
          "X-Subscription-Token" => api_key,
        }

        response = HTTP::Client.get(uri, headers: headers)

        unless response.success?
          return "Error: Search API returned #{response.status_code}"
        end

        data = JSON.parse(response.body)
        results = data.dig?("web", "results")

        unless results && results.as_a?
          return "No results for: #{query}"
        end

        items = results.as_a
        if items.empty?
          return "No results for: #{query}"
        end

        lines = ["Results for: #{query}\n"]
        items.first(count).each_with_index do |item, i|
          title = item["title"]?.try(&.as_s) || ""
          url = item["url"]?.try(&.as_s) || ""
          desc = item["description"]?.try(&.as_s)

          lines << "#{i + 1}. #{title}\n   #{url}"
          lines << "   #{desc}" if desc
        end

        lines.join("\n")
      rescue ex
        "Error: #{ex.message}"
      end
    end

    # Fetch and extract readable content from a URL.
    class WebFetchTool < Tool
      Log = ::Log.for(self)

      DEFAULT_MAX_CHARS = 50_000

      def initialize(@max_chars : Int32 = DEFAULT_MAX_CHARS)
      end

      def name : String
        "web_fetch"
      end

      def description : String
        "Fetch URL and extract readable text content."
      end

      def parameters : ToolSchema
        ToolSchema.new(
          properties: {
            "url"      => PropertySchema.new(type: "string", description: "URL to fetch"),
            "maxChars" => PropertySchema.new(type: "integer", description: "Max content chars to return", minimum: 100_i64),
          },
          required: ["url"]
        )
      end

      def execute(params : Hash(String, JSON::Any)) : String
        url_str = params["url"].as_s
        max_chars = params["maxChars"]?.try(&.as_i) || @max_chars

        if error = validate_url(url_str)
          return %({"error": "URL validation failed: #{error}", "url": "#{url_str}"})
        end

        Log.info { "Fetching: #{url_str}" }

        uri = URI.parse(url_str)
        response = fetch_with_redirects(uri)

        content_type = response.headers["Content-Type"]? || ""
        body = response.body

        text, extractor = extract_content(body, content_type)

        truncated = text.size > max_chars
        text = text[0, max_chars] if truncated

        {
          url:       url_str,
          finalUrl:  uri.to_s,
          status:    response.status_code,
          extractor: extractor,
          truncated: truncated,
          length:    text.size,
          text:      text,
        }.to_json
      rescue ex
        {error: ex.message, url: params["url"]?.try(&.as_s) || ""}.to_json
      end

      private def validate_url(url : String) : String?
        uri = URI.parse(url)
        scheme = uri.scheme
        unless scheme && {"http", "https"}.includes?(scheme)
          return "Only http/https allowed"
        end
        host = uri.host
        if host.nil? || host.empty?
          return "Missing domain"
        end

        if error = check_ssrf(host)
          return error
        end

        nil
      rescue
        "Invalid URL"
      end

      private def check_ssrf(host : String) : String?
        begin
          addrinfo = Socket::Addrinfo.resolve(host, "http", Socket::Family::UNSPEC, Socket::Type::STREAM)
          return "Cannot resolve host" if addrinfo.empty?

          ip_str = addrinfo.first.ip_address.address

          # Block private IP ranges (RFC 1918)
          if private_ip?(ip_str)
            return "Access to private IP addresses is blocked"
          end

          # Block localhost/loopback
          if loopback?(ip_str)
            return "Access to localhost is blocked"
          end

          # Block cloud metadata endpoints
          if cloud_metadata?(ip_str)
            return "Access to cloud metadata endpoints is blocked"
          end

          # Block link-local addresses
          if link_local?(ip_str)
            return "Access to link-local addresses is blocked"
          end
        rescue
          # If we can't resolve, block it to be safe
          return "Cannot validate host"
        end

        nil
      end

      private def private_ip?(ip : String) : Bool
        # IPv4 RFC 1918 private ranges
        return true if ip.starts_with?("10.")                       # 10.0.0.0/8
        return true if ip.starts_with?("192.168.")                  # 192.168.0.0/16
        return true if ip.matches?(/^172\.(1[6-9]|2[0-9]|3[01])\./) # 172.16.0.0/12

        # IPv6 private ranges
        return true if ip.starts_with?("fc") # fc00::/7 (Unique Local)
        return true if ip.starts_with?("fd") # fd00::/8 (Unique Local)

        false
      end

      private def loopback?(ip : String) : Bool
        ip.starts_with?("127.") || ip == "::1" || ip == "0.0.0.0" || ip == "::"
      end

      private def cloud_metadata?(ip : String) : Bool
        ip == "169.254.169.254" || ip == "fd00:ec2::254"
      end

      private def link_local?(ip : String) : Bool
        ip.starts_with?("169.254.") || ip.starts_with?("fe80:")
      end

      private def fetch_with_redirects(uri : URI, redirects = 0) : HTTP::Client::Response
        if redirects > MAX_REDIRECTS
          raise "Too many redirects (max #{MAX_REDIRECTS})"
        end

        headers = HTTP::Headers{"User-Agent" => USER_AGENT}
        response = HTTP::Client.get(uri, headers: headers)

        if response.status.redirection? && (location = response.headers["Location"]?)
          new_uri = URI.parse(location)
          # Handle relative redirects
          unless new_uri.host
            new_uri = uri.resolve(new_uri)
          end

          if error = validate_redirect_uri(new_uri)
            raise "Redirect blocked: #{error}"
          end

          return fetch_with_redirects(new_uri, redirects + 1)
        end

        response
      end

      private def validate_redirect_uri(uri : URI) : String?
        scheme = uri.scheme
        unless scheme && {"http", "https"}.includes?(scheme)
          return "Only http/https redirects allowed"
        end

        host = uri.host
        return "Redirect missing host" if host.nil? || host.empty?

        # Check for SSRF in redirect target
        check_ssrf(host)
      end

      private def extract_content(body : String, content_type : String) : {String, String}
        if content_type.includes?("application/json")
          begin
            parsed = JSON.parse(body)
            return {parsed.to_pretty_json, "json"}
          rescue
            return {body, "raw"}
          end
        end

        if content_type.includes?("text/html") || body.lstrip[0, 256]?.try(&.downcase.starts_with?("<!doctype")) || body.lstrip[0, 256]?.try(&.downcase.starts_with?("<html"))
          text = strip_html(body)
          return {normalize_whitespace(text), "html"}
        end

        {body, "raw"}
      end

      private def strip_html(html : String) : String
        text = html
        # Remove script and style blocks
        text = text.gsub(/<script[\s\S]*?<\/script>/im, "")
        text = text.gsub(/<style[\s\S]*?<\/style>/im, "")
        # Convert some elements to readable form
        text = text.gsub(/<br\s*\/?>/i, "\n")
        text = text.gsub(/<\/(p|div|section|article|h[1-6]|li)>/i, "\n\n")
        # Strip remaining tags
        text = text.gsub(/<[^>]+>/, "")
        # Decode common HTML entities
        text = decode_entities(text)
        text
      end

      private def decode_entities(text : String) : String
        text
          .gsub("&amp;", "&")
          .gsub("&lt;", "<")
          .gsub("&gt;", ">")
          .gsub("&quot;", "\"")
          .gsub("&#39;", "'")
          .gsub("&nbsp;", " ")
      end

      private def normalize_whitespace(text : String) : String
        text = text.gsub(/[ \t]+/, " ")
        text = text.gsub(/\n{3,}/, "\n\n")
        text.strip
      end
    end
  end
end
