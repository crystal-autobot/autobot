module Autobot
  class RetryBackoff
    getter delay : Time::Span

    def initialize(@initial : Time::Span, @max : Time::Span)
      @delay = @initial
    end

    def reset : Nil
      @delay = @initial
    end

    def next_delay : Time::Span
      current = @delay
      @delay = {@delay * 2, @max}.min
      current
    end
  end
end
