require "log"

module Autobot
  module Tools
    class RateLimiter
      Log = ::Log.for(self)

      # Rate limit configuration
      struct Limit
        property max_calls : Int32
        property window_seconds : Int32

        def initialize(@max_calls : Int32, @window_seconds : Int32)
        end
      end

      # Track calls for a specific key (tool name, session, etc.)
      private class CallTracker
        property calls : Array(Time)

        def initialize
          @calls = [] of Time
        end

        def add_call(now : Time) : Nil
          @calls << now
        end

        def cleanup(cutoff : Time) : Nil
          @calls.reject! { |call_time| call_time < cutoff }
        end

        def count : Int32
          @calls.size
        end
      end

      @trackers : Hash(String, CallTracker)
      @mutex : Mutex
      @per_tool_limits : Hash(String, Limit)
      @global_limit : Limit?

      def initialize(
        @per_tool_limits = {} of String => Limit,
        @global_limit : Limit? = nil,
      )
        @trackers = {} of String => CallTracker
        @mutex = Mutex.new

        # Default limits for high-risk tools
        @per_tool_limits["exec"] ||= Limit.new(max_calls: 10, window_seconds: 60)
        @per_tool_limits["web_fetch"] ||= Limit.new(max_calls: 20, window_seconds: 60)
        @per_tool_limits["web_search"] ||= Limit.new(max_calls: 10, window_seconds: 60)

        # Default global limit: 100 calls per minute
        @global_limit ||= Limit.new(max_calls: 100, window_seconds: 60)
      end

      # Check if a tool call is allowed
      # Returns nil if allowed, error message if rate limited
      def check_limit(tool_name : String, session_key : String) : String?
        now = Time.utc

        @mutex.synchronize do
          # Check tool-specific limit
          if limit = @per_tool_limits[tool_name]?
            if error = check_specific_limit("tool:#{tool_name}", limit, now)
              Log.warn { "Rate limit exceeded for tool #{tool_name}" }
              return error
            end
          end

          # Check per-session limit for this tool
          session_limit = Limit.new(max_calls: 30, window_seconds: 60)
          if error = check_specific_limit("session:#{session_key}:#{tool_name}", session_limit, now)
            Log.warn { "Session rate limit exceeded for #{session_key}" }
            return error
          end

          # Check global limit
          if limit = @global_limit
            if error = check_specific_limit("global", limit, now)
              Log.warn { "Global rate limit exceeded" }
              return error
            end
          end
        end

        nil
      end

      # Record a successful tool call
      def record_call(tool_name : String, session_key : String) : Nil
        now = Time.utc

        @mutex.synchronize do
          record_to_tracker("tool:#{tool_name}", now)
          record_to_tracker("session:#{session_key}:#{tool_name}", now)
          record_to_tracker("global", now)
        end
      end

      # Reset rate limits (useful for testing)
      def reset : Nil
        @mutex.synchronize do
          @trackers.clear
        end
      end

      # Get current call count for a key (for monitoring)
      def current_count(key : String) : Int32
        @mutex.synchronize do
          @trackers[key]?.try(&.count) || 0
        end
      end

      private def check_specific_limit(key : String, limit : Limit, now : Time) : String?
        tracker = @trackers[key] ||= CallTracker.new

        # Remove expired calls
        cutoff = now - limit.window_seconds.seconds
        tracker.cleanup(cutoff)

        # Check if limit exceeded
        if tracker.count >= limit.max_calls
          return "Rate limit exceeded: max #{limit.max_calls} calls per #{limit.window_seconds} seconds"
        end

        nil
      end

      private def record_to_tracker(key : String, now : Time) : Nil
        tracker = @trackers[key] ||= CallTracker.new
        tracker.add_call(now)
      end
    end
  end
end
