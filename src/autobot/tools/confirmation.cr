require "json"
require "random/secure"

module Autobot::Tools
  struct PendingConfirmation
    getter code : String
    getter name : String
    getter params : Hash(String, JSON::Any)
    getter expires_at : Time

    def initialize(@code : String, @name : String, @params : Hash(String, JSON::Any), @expires_at : Time)
    end

    def expired?(now : Time = Time.utc) : Bool
      now > @expires_at
    end
  end

  # One pending gated tool call per session, redeemed by typing its code.
  class ConfirmationStore
    TTL           = 5.minutes
    CODE_LENGTH   = 4
    CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

    @pending = {} of String => PendingConfirmation
    @mutex = Mutex.new

    def request(session_key : String, name : String, params : Hash(String, JSON::Any), ttl : Time::Span = TTL) : PendingConfirmation
      pending = PendingConfirmation.new(generate_code, name, params, Time.utc + ttl)
      @mutex.synchronize { @pending[session_key] = pending }
      pending
    end

    def take(session_key : String, text : String) : PendingConfirmation?
      @mutex.synchronize do
        pending = @pending[session_key]?
        return nil unless pending

        if pending.expired?
          @pending.delete(session_key)
          return nil
        end
        return nil unless text.strip.upcase == pending.code

        @pending.delete(session_key)
      end
    end

    def pending?(session_key : String) : Bool
      @mutex.synchronize { @pending.has_key?(session_key) }
    end

    private def generate_code : String
      String.build(CODE_LENGTH) do |io|
        CODE_LENGTH.times { io << CODE_ALPHABET[Random::Secure.rand(CODE_ALPHABET.size)] }
      end
    end
  end
end
