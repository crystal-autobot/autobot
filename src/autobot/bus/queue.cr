require "./events"

module Autobot::Bus
  # Event-driven message bus using Crystal channels for async communication
  class MessageBus
    Log = ::Log.for("bus")

    @inbound : Channel(InboundMessage)
    @outbound : Channel(OutboundEvent)
    @stopped : Bool = false

    def initialize(capacity : Int32 = 100)
      @inbound = Channel(InboundMessage).new(capacity)
      @outbound = Channel(OutboundEvent).new(capacity)
    end

    # Publish an inbound message (from channels to agent)
    def publish_inbound(message : InboundMessage) : Nil
      return if @stopped

      Log.debug { "Inbound: #{message.channel}:#{message.chat_id} - #{message.content[0..50]}" }
      @inbound.send(message)
    end

    # Consume inbound messages (agent reads these)
    def consume_inbound(&block : InboundMessage -> Nil) : Nil
      spawn do
        loop do
          break if @stopped

          begin
            select
            when msg = @inbound.receive
              begin
                block.call(msg)
              rescue ex
                Log.error { "Error processing inbound message: #{ex.message}" }
                Log.error { ex.backtrace.join("\n") }
              end
            when timeout(5.seconds)
              # Periodic check for @stopped
              break if @stopped
            end
          rescue Channel::ClosedError
            # Channel closed during shutdown - exit gracefully
            break
          end
        end
        Log.info { "Inbound consumer stopped" }
      end
    end

    # Publish an outbound message (from agent to channels)
    def publish_outbound(message : OutboundMessage) : Nil
      return if @stopped

      Log.debug { "Outbound: #{message.channel}:#{message.chat_id} - #{message.content[0..50]}" }
      @outbound.send(message)
    end

    def publish_turn_ended(channel : String, chat_id : String) : Nil
      return if @stopped

      Log.debug { "Turn ended: #{channel}:#{chat_id}" }
      @outbound.send(TurnEnded.new(channel, chat_id))
    end

    # Consume outbound events (channels read these)
    def consume_outbound(&block : OutboundEvent -> Nil) : Nil
      spawn do
        loop do
          break if @stopped

          begin
            select
            when event = @outbound.receive
              begin
                block.call(event)
              rescue ex
                Log.error { "Error processing outbound event: #{ex.message}" }
                Log.error { ex.backtrace.join("\n") }
              end
            when timeout(5.seconds)
              # Periodic check for @stopped
              break if @stopped
            end
          rescue Channel::ClosedError
            # Channel closed during shutdown - exit gracefully
            break
          end
        end
        Log.info { "Outbound consumer stopped" }
      end
    end

    # Stop the bus gracefully
    def stop : Nil
      Log.info { "Stopping message bus..." }
      @stopped = true

      # Close channels
      @inbound.close
      @outbound.close
    end

    # Check if bus is stopped
    def stopped? : Bool
      @stopped
    end
  end
end
