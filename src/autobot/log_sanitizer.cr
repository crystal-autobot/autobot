module Autobot
  module LogSanitizer
    PATTERNS = [
      # API key parameters in URLs (check early to catch before generic pattern)
      {pattern: /([?&])(api_key|apikey|key|token)=([^&\s]+)/i, replacement: "\\1\\2=[REDACTED]"},

      # Bearer tokens
      {pattern: /Bearer\s+[A-Za-z0-9_\-\.]+/i, replacement: "Bearer [REDACTED]"},

      # Anthropic API keys (sk-ant-)
      {pattern: /sk-ant-[A-Za-z0-9_-]+/, replacement: "sk-ant-[REDACTED]"},

      # OpenAI API keys (sk-)
      {pattern: /sk-[A-Za-z0-9]{16,}/, replacement: "sk-[REDACTED]"},

      # AWS keys
      {pattern: /AKIA[A-Z0-9]{16}/, replacement: "AKIA[REDACTED]"},

      # Generic tokens in key=value format
      {pattern: /token[=:]\s*['"]*([A-Za-z0-9_\-\.]+)['"]*\b/i, replacement: "token=[REDACTED]"},

      # Passwords in URLs or params
      {pattern: /password[=:]\s*['"]*([^&\s'"]+)['"]*\b/i, replacement: "password=[REDACTED]"},

      # Authorization headers with values
      {pattern: /Authorization:\s*([^\s]+)/i, replacement: "Authorization: [REDACTED]"},

      # X-API-Key headers
      {pattern: /x-api-key:\s*([^\s]+)/i, replacement: "x-api-key: [REDACTED]"},

      # Generic API keys (20+ chars, must be after specific patterns)
      {pattern: /\b[A-Za-z0-9_-]{20,}\b/, replacement: "[REDACTED_KEY]"},
    ]

    # Sanitize a log message by redacting sensitive patterns
    def self.sanitize(message : String) : String
      result = message

      PATTERNS.each do |pattern_info|
        result = result.gsub(pattern_info[:pattern], pattern_info[:replacement])
      end

      result
    end

    # Sanitize a URL by redacting query parameters that might contain secrets
    def self.sanitize_url(url : String) : String
      uri = URI.parse(url)

      # Redact sensitive query parameters
      if query = uri.query
        sanitized_params = query.split('&').map do |param|
          key = param.split('=', 2).first
          if key && {"api_key", "apikey", "key", "token", "secret", "password"}.includes?(key.downcase)
            "#{key}=[REDACTED]"
          else
            param
          end
        end
        uri.query = sanitized_params.join('&')
      end

      uri.to_s
    rescue
      # If URL parsing fails, do basic sanitization
      sanitize(url)
    end

    # Check if a string looks like it contains sensitive data
    def self.contains_sensitive_data?(text : String) : Bool
      PATTERNS.any?(&.[:pattern].matches?(text))
    end
  end
end
