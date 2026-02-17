module Autobot
  module LogSanitizer
    URL_KEY_PARAMS = /([?&])(api_key|apikey|key|token)=([^&\s]+)/i
    BEARER_TOKEN   = /Bearer\s+[A-Za-z0-9_\-\.]+/i
    ANTHROPIC_KEY  = /sk-ant-[A-Za-z0-9_-]+/
    OPENAI_KEY     = /sk-[A-Za-z0-9]{16,}/
    AWS_KEY        = /AKIA[A-Z0-9]{16}/
    TOKEN_VALUE    = /token[=:]\s*['"]*([A-Za-z0-9_\-\.]+)['"]*\b/i
    PASSWORD_VALUE = /password[=:]\s*['"]*([^&\s'"]+)['"]*\b/i
    AUTH_HEADER    = /Authorization:\s*([^\s]+)/i
    API_KEY_HEADER = /x-api-key:\s*([^\s]+)/i
    GENERIC_KEY    = /\b[A-Za-z0-9]+[-_]?[A-Za-z0-9]{20,}\b/

    SENSITIVE_URL_PARAMS = {"api_key", "apikey", "key", "token", "secret", "password"}

    PATTERNS = [
      {pattern: URL_KEY_PARAMS, replacement: "\\1\\2=[REDACTED]"},
      {pattern: BEARER_TOKEN, replacement: "Bearer [REDACTED]"},
      {pattern: ANTHROPIC_KEY, replacement: "sk-ant-[REDACTED]"},
      {pattern: OPENAI_KEY, replacement: "sk-[REDACTED]"},
      {pattern: AWS_KEY, replacement: "AKIA[REDACTED]"},
      {pattern: TOKEN_VALUE, replacement: "token=[REDACTED]"},
      {pattern: PASSWORD_VALUE, replacement: "password=[REDACTED]"},
      {pattern: AUTH_HEADER, replacement: "Authorization: [REDACTED]"},
      {pattern: API_KEY_HEADER, replacement: "x-api-key: [REDACTED]"},
      {pattern: GENERIC_KEY, replacement: "[REDACTED_KEY]"},
    ]

    def self.sanitize(message : String) : String
      result = message

      PATTERNS.each do |pattern_info|
        result = result.gsub(pattern_info[:pattern], pattern_info[:replacement])
      end

      result
    end

    def self.sanitize_url(url : String) : String
      uri = URI.parse(url)

      if query = uri.query
        sanitized_params = query.split('&').map do |param|
          key = param.split('=', 2).first
          if key && SENSITIVE_URL_PARAMS.includes?(key.downcase)
            "#{key}=[REDACTED]"
          else
            param
          end
        end
        uri.query = sanitized_params.join('&')
      end

      uri.to_s
    rescue
      sanitize(url)
    end

    def self.contains_sensitive_data?(text : String) : Bool
      PATTERNS.any?(&.[:pattern].matches?(text))
    end
  end
end
