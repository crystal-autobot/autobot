require "./types"

module Autobot
  module Cron
    # Shared formatting helpers for cron schedules and relative times.
    # Used by CronTool, TelegramChannel, and CronCmd.
    module Formatter
      MS_PER_SECOND      = 1000
      SECONDS_PER_MINUTE =   60
      MINUTES_PER_HOUR   =   60
      HOURS_PER_DAY      =   24
      TIME_FORMAT        = "%Y-%m-%d %H:%M UTC"

      def self.format_schedule(schedule : CronSchedule) : String
        case schedule.kind
        when .every?
          every = schedule.every_ms
          every ? "every #{format_duration(every)}" : "every ?"
        when .cron?
          schedule.expr || ""
        when .at?
          at_ms = schedule.at_ms
          at_ms ? "one-time: #{Time.unix_ms(at_ms).to_s(TIME_FORMAT)}" : "one-time"
        else
          "unknown"
        end
      end

      def self.format_relative_time(time_ms : Int64?) : String
        return "pending" unless time_ms

        now = Time.utc.to_unix_ms
        diff_ms = now - time_ms

        if diff_ms >= 0
          format_past_time(diff_ms)
        else
          format_future_time(-diff_ms)
        end
      end

      def self.format_duration(ms : Int64) : String
        seconds = ms // MS_PER_SECOND
        return "#{seconds}s" if seconds < SECONDS_PER_MINUTE

        minutes = seconds // SECONDS_PER_MINUTE
        return "#{minutes} min" if minutes < MINUTES_PER_HOUR

        hours = minutes // MINUTES_PER_HOUR
        return "#{hours}h" if hours < HOURS_PER_DAY

        days = hours // HOURS_PER_DAY
        "#{days}d"
      end

      private def self.format_past_time(diff_ms : Int64) : String
        seconds = diff_ms // MS_PER_SECOND
        return "just now" if seconds < SECONDS_PER_MINUTE

        minutes = seconds // SECONDS_PER_MINUTE
        return "#{minutes} min ago" if minutes < MINUTES_PER_HOUR

        hours = minutes // MINUTES_PER_HOUR
        return "#{hours}h ago" if hours < HOURS_PER_DAY

        days = hours // HOURS_PER_DAY
        "#{days}d ago"
      end

      private def self.format_future_time(diff_ms : Int64) : String
        seconds = diff_ms // MS_PER_SECOND
        return "in <1 min" if seconds < SECONDS_PER_MINUTE

        minutes = seconds // SECONDS_PER_MINUTE
        return "in #{minutes} min" if minutes < MINUTES_PER_HOUR

        hours = minutes // MINUTES_PER_HOUR
        return "in #{hours}h" if hours < HOURS_PER_DAY

        days = hours // HOURS_PER_DAY
        "in #{days}d"
      end
    end
  end
end
