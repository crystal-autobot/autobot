module Autobot
  module Tools
    # Result of a tool execution with explicit success/error status
    struct ToolResult
      enum Status
        Success
        Error        # Regular errors (file not found, invalid params, API failures)
        AccessDenied # Security/permission errors (workspace restrictions, dangerous commands, SSRF, rate limits)
      end

      getter status : Status
      getter content : String

      def initialize(@status : Status, @content : String)
      end

      def self.success(content : String) : ToolResult
        new(Status::Success, content)
      end

      def self.error(message : String) : ToolResult
        new(Status::Error, message)
      end

      def self.access_denied(message : String) : ToolResult
        new(Status::AccessDenied, message)
      end

      def success? : Bool
        @status.success?
      end

      def error? : Bool
        !success?
      end

      def access_denied? : Bool
        @status.access_denied?
      end

      def to_s : String
        @content
      end
    end
  end
end
