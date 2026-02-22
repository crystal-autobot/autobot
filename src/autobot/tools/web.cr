require "http/client"
require "json"
require "log"
require "uri"
require "./result"

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

      def execute(params : Hash(String, JSON::Any)) : ToolResult
        api_key = @api_key
        return ToolResult.error("BRAVE_API_KEY not configured") if api_key.nil? || api_key.empty?

        query = params["query"].as_s
        count = Math.min(Math.max(params["count"]?.try(&.as_i) || @max_results, 1), 10)

        Log.info { "Web search: #{query} (count: #{count})" }

        results = fetch_search_results(query, count, api_key)
        format_search_results(query, results, count)
      rescue ex
        ToolResult.error(ex.message || "Unknown error")
      end

      private def fetch_search_results(query : String, count : Int32, api_key : String) : Array(JSON::Any)?
        uri = URI.parse("https://api.search.brave.com/res/v1/web/search")
        uri.query = URI::Params.encode({"q" => query, "count" => count.to_s})

        headers = HTTP::Headers{
          "Accept"               => "application/json",
          "X-Subscription-Token" => api_key,
        }

        response = HTTP::Client.get(uri, headers: headers)
        raise "Search API returned #{response.status_code}" unless response.success?

        data = JSON.parse(response.body)
        data.dig?("web", "results").try(&.as_a?)
      end

      private def format_search_results(query : String, results : Array(JSON::Any)?, count : Int32) : ToolResult
        return ToolResult.success("No results for: #{query}") if results.nil? || results.empty?

        lines = ["Results for: #{query}\n"]
        results.first(count).each_with_index do |item, i|
          title = item["title"]?.try(&.as_s) || ""
          url = item["url"]?.try(&.as_s) || ""
          desc = item["description"]?.try(&.as_s)

          lines << "#{i + 1}. #{title}\n   #{url}"
          lines << "   #{desc}" if desc
        end

        ToolResult.success(lines.join("\n"))
      end
    end

    # Fetch and extract readable content from a URL.
    class WebFetchTool < Tool
      Log = ::Log.for(self)

      DEFAULT_MAX_CHARS = 20_000

      # SSRF protection patterns for alternate IP notation
      OCTAL_IP_PATTERN      = /\b0[0-7]+\.\d+\.\d+\.\d+/
      HEX_IP_PATTERN        = /\b0x[0-9a-f]+/i
      INTEGER_IP_PATTERN    = /^\d{8,}$/
      IPV6_LOOPBACK_PATTERN = /\[::1\]/
      IPV6_PRIVATE_PATTERN  = /\[(fc|fd)[0-9a-f]{2}:/i

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

      def execute(params : Hash(String, JSON::Any)) : ToolResult
        url_str = params["url"].as_s
        max_chars = params["maxChars"]?.try(&.as_i) || @max_chars

        if error = validate_url(url_str)
          return ToolResult.access_denied("URL validation failed: #{error}")
        end

        Log.info { "Fetching: #{url_str}" }

        uri = URI.parse(url_str)
        response = fetch_with_redirects(uri)

        content_type = response.headers["Content-Type"]? || ""
        body = response.body

        text, _extractor = extract_content(body, content_type)

        truncated = text.size > max_chars
        text = text[0, max_chars] if truncated

        result = String.build do |io|
          io << "[" << url_str << "]\n"
          io << "(truncated to " << max_chars << " chars)\n" if truncated
          io << text
        end

        ToolResult.success(result)
      rescue ex
        ToolResult.error(ex.message || "Unknown error")
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

      private def resolve_and_validate_ip(host : String) : String
        # First check if host looks like an IP address with alternate notation
        if error = check_alternate_ip_notation(host)
          raise error
        end

        addrinfo = Socket::Addrinfo.resolve(host, "http", Socket::Family::UNSPEC, Socket::Type::STREAM)
        raise "Cannot resolve host" if addrinfo.empty?

        # Validate ALL resolved IPs, not just the first one
        validated_ips = [] of String

        addrinfo.each do |addr|
          ip_str = addr.ip_address.address

          if private_ip?(ip_str)
            raise "Access to private IP addresses is blocked"
          end

          if loopback?(ip_str)
            raise "Access to localhost is blocked"
          end

          if cloud_metadata?(ip_str)
            raise "Access to cloud metadata endpoints is blocked"
          end

          if link_local?(ip_str)
            raise "Access to link-local addresses is blocked"
          end

          validated_ips << ip_str
        end

        raise "No valid IPs found" if validated_ips.empty?

        # Return first validated IP to connect to (prevents DNS rebinding)
        validated_ips.first
      rescue ex
        raise "SSRF validation failed: #{ex.message}"
      end

      private def check_ssrf(host : String) : String?
        resolve_and_validate_ip(host)
        nil
      rescue ex
        ex.message
      end

      private def check_alternate_ip_notation(host : String) : String?
        return "Octal IP notation is blocked" if host.match(OCTAL_IP_PATTERN)
        return "Hex IP notation is blocked" if host.match(HEX_IP_PATTERN)
        return "Integer IP notation is blocked" if host.match(INTEGER_IP_PATTERN)

        if host.includes?("[")
          return "Access to localhost is blocked" if host.match(IPV6_LOOPBACK_PATTERN)
          return "Access to private addresses is blocked" if host.match(IPV6_PRIVATE_PATTERN)
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

        hostname = uri.host
        raise "Invalid URI: missing host" unless hostname

        # Validate all resolved IPs before connecting (SSRF protection)
        validated_ip = resolve_and_validate_ip(hostname)

        headers = HTTP::Headers{"User-Agent" => USER_AGENT}

        if uri.scheme == "https"
          # HTTPS: connect via hostname for proper SNI/cert validation.
          # DNS rebinding is mitigated by TLS — a rebind target won't have
          # a valid certificate for the original hostname.
          client = HTTP::Client.new(hostname, uri.port, tls: true)
        else
          # HTTP: connect to validated IP to prevent DNS rebinding.
          headers["Host"] = hostname
          client = HTTP::Client.new(validated_ip, uri.port)
        end
        client.read_timeout = DEFAULT_TIMEOUT
        client.connect_timeout = DEFAULT_TIMEOUT

        begin
          response = client.get(uri.request_target, headers: headers)

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
        ensure
          client.close
        end
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
