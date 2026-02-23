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

      HTML_TIME_FORMAT = "%b %-d, %H:%M UTC"

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

      # HTML-safe schedule string with emoji prefix, suitable for Telegram and similar channels.
      def self.format_schedule_html(schedule : CronSchedule) : String
        case schedule.kind
        when .every?
          every = schedule.every_ms
          every ? "⏱ Every #{format_duration(every)}" : "⏱ Every ?"
        when .cron?
          "🕐 #{escape_html(schedule.expr || "")} (UTC)"
        when .at?
          at_ms = schedule.at_ms
          at_ms ? "📌 One-time: #{Time.unix_ms(at_ms).to_s(HTML_TIME_FORMAT)}" : "📌 One-time"
        else
          "❓ Unknown"
        end
      end

      # HTML-safe last-run string with emoji status indicator.
      def self.format_last_run_html(last_run_at_ms : Int64?) : String
        if last_run_at_ms
          "✅ #{format_relative_time(last_run_at_ms)}"
        else
          "⏳ pending"
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
        if minutes < MINUTES_PER_HOUR
          rem = seconds % SECONDS_PER_MINUTE
          return rem > 0 ? "#{minutes} min #{rem}s" : "#{minutes} min"
        end

        hours = minutes // MINUTES_PER_HOUR
        if hours < HOURS_PER_DAY
          rem = minutes % MINUTES_PER_HOUR
          return rem > 0 ? "#{hours}h #{rem} min" : "#{hours}h"
        end

        days = hours // HOURS_PER_DAY
        rem = hours % HOURS_PER_DAY
        rem > 0 ? "#{days}d #{rem}h" : "#{days}d"
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

      # Plain-text type tag for LLM tool output.
      def self.format_type_tag(job : CronJob) : String
        job.payload.kind.exec? ? "[exec]" : "[agent]"
      end

      # Job detail (command or message) based on job type.
      def self.format_job_detail(job : CronJob) : String
        if job.payload.kind.exec?
          job.payload.command || ""
        else
          job.payload.message
        end
      end

      # Markdown-formatted exec job output notification.
      def self.format_exec_output(job : CronJob, output : String) : String
        "⚡ **#{job.name}**\n\n```\n#{output}\n```"
      end

      # HTML-formatted job line for Telegram cron list.
      def self.format_job_line_html(job : CronJob, index : Int32) : String
        schedule = format_schedule_html(job.schedule)
        last_run = format_last_run_html(job.state.last_run_at_ms)
        type_icon = job.payload.kind.exec? ? "⚡" : "🤖"
        detail = escape_html(format_job_detail(job).strip)

        "<b>#{index}.</b> #{type_icon} #{escape_html(job.id)} — #{escape_html(job.name)}\n" \
        "   #{schedule} | #{last_run}\n" \
        "   <i>#{detail}</i>"
      end

      def self.escape_html(s : String) : String
        s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub("\"", "&quot;")
      end
    end
  end
end
