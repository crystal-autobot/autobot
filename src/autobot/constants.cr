module Autobot
  # Shared constants used across the application
  module Constants
    # Message roles
    ROLE_USER      = "user"
    ROLE_ASSISTANT = "assistant"
    ROLE_SYSTEM    = "system"
    ROLE_TOOL      = "tool"

    # Channel names
    CHANNEL_SYSTEM   = "system"
    CHANNEL_CLI      = "cli"
    CHANNEL_TELEGRAM = "telegram"
    CHANNEL_SLACK    = "slack"
    CHANNEL_WHATSAPP = "whatsapp"

    # Sender ID prefixes
    CRON_SENDER_PREFIX = "cron:"

    # Session keys
    DEFAULT_SESSION_KEY = "cli:direct"
    DEFAULT_CHAT_ID     = "direct"

    # Common output messages
    NO_OUTPUT_MESSAGE = "(no output)"

    # HTTP Status codes
    HTTP_STATUS_OK = 200
  end
end
