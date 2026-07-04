require "./autobot"

# Ensure standard streams are line-buffered/flushed immediately
# to prevent output delays under non-TTY supervisors (like systemd journald).
STDOUT.sync = true
STDERR.sync = true

# Normal CLI mode
Autobot.run
