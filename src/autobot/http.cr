require "http/client"
require "http_proxy"
require "uri"

module Autobot
  # Centralized HTTP utility for managing HTTP::Client instances, timeouts,
  # proxy routing, and deterministic exception-safe socket closure.
  module HTTP
    alias Client = ::HTTP::Client
    alias Headers = ::HTTP::Headers
    alias Request = ::HTTP::Request

    Log = ::Log.for("autobot.http")

    DEFAULT_DNS_TIMEOUT     = 10.seconds
    REQUEST_CONNECT_TIMEOUT = 10.seconds
    DEFAULT_READ_TIMEOUT    = 30.seconds

    # Constructs an `HTTP::Client` configured with standard timeouts.
    def self.build_client(
      uri : URI | String,
      connect_timeout : Time::Span = REQUEST_CONNECT_TIMEOUT,
      read_timeout : Time::Span? = DEFAULT_READ_TIMEOUT,
      dns_timeout : Time::Span? = DEFAULT_DNS_TIMEOUT,
    ) : ::HTTP::Client
      parsed_uri = uri.is_a?(String) ? URI.parse(uri) : uri
      client = ::HTTP::Client.new(parsed_uri)
      client.connect_timeout = connect_timeout
      client.read_timeout = read_timeout if read_timeout
      client.dns_timeout = dns_timeout if dns_timeout
      client
    end

    # Executes a block with a provided `HTTP::Client`, guaranteeing socket closure via `ensure`.
    def self.with_client(
      client : ::HTTP::Client,
      proxy : String? = nil,
      &
    )
      begin
        if proxy
          apply_proxy(client, proxy)
        end
        yield client
      ensure
        begin
          client.close
        rescue ex
          Log.debug(exception: ex) { "Error during client close" }
        end
      end
    end

    # Executes a block with an `HTTP::Client` constructed from `uri`, guaranteeing socket closure via `ensure`.
    def self.with_client(
      uri : URI | String,
      proxy : String? = nil,
      connect_timeout : Time::Span = REQUEST_CONNECT_TIMEOUT,
      read_timeout : Time::Span? = DEFAULT_READ_TIMEOUT,
      dns_timeout : Time::Span? = DEFAULT_DNS_TIMEOUT,
      &
    )
      client = build_client(
        uri,
        connect_timeout: connect_timeout,
        read_timeout: read_timeout,
        dns_timeout: dns_timeout
      )
      with_client(client, proxy: proxy) do |http_client|
        yield http_client
      end
    end

    # Applies an HTTP proxy to the given client instance.
    def self.apply_proxy(client : ::HTTP::Client, proxy_url : String) : Nil
      uri = URI.parse(proxy_url)
      host = uri.host
      return unless host

      client.proxy = ::HTTP::Proxy::Client.new(host, uri.port || 8080)
    rescue ex
      Log.error { "Failed to configure proxy (#{proxy_url}): #{ex.message}" }
      raise ex
    end
  end
end
