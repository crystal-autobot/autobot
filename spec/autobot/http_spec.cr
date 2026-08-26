require "../spec_helper"

describe Autobot::HTTP do
  describe ".build_client" do
    it "constructs client with specified uri" do
      client = Autobot::HTTP.build_client("http://example.com")
      client.should be_a(HTTP::Client)
    ensure
      client.close if client
    end
  end

  describe ".apply_proxy" do
    it "applies proxy configuration when proxy url is provided" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.port
      client = Autobot::HTTP.build_client("http://example.com")
      Autobot::HTTP.apply_proxy(client, "http://127.0.0.1:#{port}")
      client.proxy?.should be_true
      if proxy = client.proxy
        proxy.host.should eq("127.0.0.1")
        proxy.port.should eq(port)
      else
        fail("expected proxy to be configured")
      end
    ensure
      client.close if client
      server.close if server
    end
  end

  describe ".with_client" do
    it "yields client and processes request successfully" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.port

      spawn do
        if socket = server.accept?
          while (line = socket.gets) && !line.empty?
          end
          body = "ok"
          socket << "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: keep-alive\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
          socket.flush
        end
      end

      res = Autobot::HTTP.with_client("http://127.0.0.1:#{port}") do |client|
        response = client.get("/")
        response.body
      end

      res.should eq("ok")
    ensure
      server.close if server
    end

    it "guarantees client closure when block raises an exception" do
      expect_raises(ArgumentError, "block failure") do
        Autobot::HTTP.with_client("http://127.0.0.1:9999") do |_client|
          raise ArgumentError.new("block failure")
        end
      end
    end
  end

  describe "HTTP::Proxy::Client#open socket safety" do
    it "closes underlying socket when CONNECT handshake fails" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.port

      spawn do
        if socket = server.accept?
          socket.close
        end
      end

      proxy_client = HTTP::Proxy::Client.new("127.0.0.1", port)
      tls_ctx = OpenSSL::SSL::Context::Client.new

      expect_raises(Exception) do
        proxy_client.open(
          "api.telegram.org",
          443,
          tls: tls_ctx,
          dns_timeout: 2.seconds,
          connect_timeout: 2.seconds,
          read_timeout: 2.seconds,
          write_timeout: 2.seconds
        )
      end
    ensure
      server.close if server
    end

    it "closes underlying socket when TLS negotiation fails" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.port

      spawn do
        if socket = server.accept?
          while (line = socket.gets) && !line.empty?
          end
          socket << "HTTP/1.1 200 Connection established\r\n\r\n"
          socket.flush
          socket.write("invalid tls handshake".to_slice)
          socket.flush
          socket.close
        end
      end

      proxy_client = HTTP::Proxy::Client.new("127.0.0.1", port)
      tls_ctx = OpenSSL::SSL::Context::Client.new

      expect_raises(Exception) do
        proxy_client.open(
          "api.telegram.org",
          443,
          tls: tls_ctx,
          dns_timeout: 2.seconds,
          connect_timeout: 2.seconds,
          read_timeout: 2.seconds,
          write_timeout: 2.seconds
        )
      end
    ensure
      server.close if server
    end
  end
end
