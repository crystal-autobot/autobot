require "../../spec_helper"

describe Autobot::Config::McpServerConfig do
  it "deserializes from YAML" do
    config = Autobot::Config::McpServerConfig.from_yaml(<<-YAML
    command: "uvx"
    args: ["--python", "3.12", "garmin-mcp"]
    env:
      GARMIN_EMAIL: "test@example.com"
    YAML
    )
    config.command.should eq("uvx")
    config.args.should eq(["--python", "3.12", "garmin-mcp"])
    config.env["GARMIN_EMAIL"].should eq("test@example.com")
  end

  it "has sensible defaults" do
    config = Autobot::Config::McpServerConfig.from_yaml("--- {}")
    config.command.should eq("")
    config.args.should be_empty
    config.env.should be_empty
    config.tools.should be_empty
  end

  it "parses tools allowlist" do
    config = Autobot::Config::McpServerConfig.from_yaml(<<-YAML
    command: "echo"
    tools: ["get_activities", "get_heart_rate*"]
    YAML
    )
    config.tools.should eq(["get_activities", "get_heart_rate*"])
  end
end

describe Autobot::Config::McpConfig do
  it "deserializes servers from YAML" do
    config = Autobot::Config::McpConfig.from_yaml(<<-YAML
    servers:
      garmin:
        command: "uvx"
        args: ["garmin-mcp"]
      github:
        command: "npx"
        args: ["-y", "server-github"]
    YAML
    )
    config.servers.size.should eq(2)
    config.servers["garmin"].command.should eq("uvx")
    config.servers["github"].command.should eq("npx")
  end
end

describe Autobot::Config::Config do
  it "parses mcp section" do
    config = Autobot::Config::Config.from_yaml(<<-YAML
    mcp:
      servers:
        test:
          command: "echo"
    YAML
    )
    config.mcp.should_not be_nil
    config.mcp.try(&.servers.size).should eq(1)
  end

  it "allows missing mcp section" do
    config = Autobot::Config::Config.from_yaml("--- {}")
    config.mcp.should be_nil
  end
end

describe Autobot::Mcp do
  describe ".tool_allowed?" do
    it "allows all tools when allowlist is empty" do
      Autobot::Mcp.tool_allowed?("anything", [] of String).should be_true
    end

    it "allows exact match" do
      Autobot::Mcp.tool_allowed?("get_activities", ["get_activities", "get_steps"]).should be_true
    end

    it "rejects non-matching tool" do
      Autobot::Mcp.tool_allowed?("delete_all", ["get_activities", "get_steps"]).should be_false
    end

    it "supports prefix matching with *" do
      Autobot::Mcp.tool_allowed?("get_heart_rate_daily", ["get_heart_rate*"]).should be_true
      Autobot::Mcp.tool_allowed?("get_steps", ["get_heart_rate*"]).should be_false
    end

    it "matches exact name even with * pattern present" do
      Autobot::Mcp.tool_allowed?("list_workouts", ["get_*", "list_workouts"]).should be_true
    end
  end
end

describe Autobot::Mcp::ProxyTool do
  describe ".build_name" do
    it "creates prefixed name" do
      Autobot::Mcp::ProxyTool.build_name("garmin", "list_activities").should eq("mcp_garmin_list_activities")
    end

    it "sanitizes special characters" do
      Autobot::Mcp::ProxyTool.build_name("my-server", "get-data").should eq("mcp_my_server_get_data")
    end

    it "sanitizes uppercase" do
      Autobot::Mcp::ProxyTool.build_name("GitHub", "ListRepos").should eq("mcp_github_listrepos")
    end

    it "collapses multiple underscores" do
      Autobot::Mcp::ProxyTool.build_name("a--b", "c..d").should eq("mcp_a_b_c_d")
    end
  end

  describe ".convert_schema" do
    it "converts simple properties" do
      raw = JSON.parse(%({"type":"object","properties":{"query":{"type":"string","description":"Search query"}},"required":["query"]}))
      schema = Autobot::Mcp::ProxyTool.convert_schema(raw)

      schema.properties.size.should eq(1)
      schema.properties["query"].type.should eq("string")
      schema.properties["query"].description.should eq("Search query")
      schema.required.should eq(["query"])
    end

    it "handles missing schema gracefully" do
      schema = Autobot::Mcp::ProxyTool.convert_schema(nil)
      schema.properties.should be_empty
      schema.required.should be_empty
    end

    it "falls back to string for unknown types" do
      raw = JSON.parse(%({"type":"object","properties":{"x":{"type":"unknown_type"}}}))
      schema = Autobot::Mcp::ProxyTool.convert_schema(raw)
      schema.properties["x"].type.should eq("string")
    end

    it "handles array type with items" do
      raw = JSON.parse(%({"type":"object","properties":{"ids":{"type":"array","items":{"type":"integer"}}}}))
      schema = Autobot::Mcp::ProxyTool.convert_schema(raw)
      schema.properties["ids"].type.should eq("array")
      schema.properties["ids"].items.try(&.type).should eq("integer")
    end

    it "handles enum values" do
      raw = JSON.parse(%({"type":"object","properties":{"sort":{"type":"string","enum":["asc","desc"]}}}))
      schema = Autobot::Mcp::ProxyTool.convert_schema(raw)
      schema.properties["sort"].enum_values.should eq(["asc", "desc"])
    end
  end

  describe "#to_schema" do
    it "uses raw input schema when available" do
      tool_json = JSON.parse(%({"name":"search","description":"Search things","inputSchema":{"type":"object","properties":{"q":{"type":"string","description":"query"}},"required":["q"]}}))

      # Use from_mcp_tool with a stubbed client
      client = Autobot::Mcp::Client.new(
        server_name: "test",
        command: "echo",
      )

      proxy = Autobot::Mcp::ProxyTool.from_mcp_tool(client, tool_json)
      schema = proxy.to_schema

      schema["type"].as_s.should eq("function")
      func = schema["function"].as_h
      func["name"].as_s.should eq("mcp_test_search")
      func["description"].as_s.should eq("[test] Search things")

      # Parameters should be the raw inputSchema, not the converted one
      params = func["parameters"].as_h
      params["type"].as_s.should eq("object")
      params["properties"].as_h.has_key?("q").should be_true
    end
  end
end
