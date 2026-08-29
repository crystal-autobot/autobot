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
end
