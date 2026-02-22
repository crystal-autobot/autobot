require "../../spec_helper"

describe Autobot::Tools::ToolSchema do
  describe "#validate" do
    it "passes with valid required parameters" do
      schema = Autobot::Tools::ToolSchema.new(
        properties: {
          "name" => Autobot::Tools::PropertySchema.new(type: "string", description: "Name"),
        },
        required: ["name"]
      )

      errors = schema.validate({"name" => JSON::Any.new("test")})
      errors.should be_empty
    end

    it "fails when required parameter is missing" do
      schema = Autobot::Tools::ToolSchema.new(
        properties: {
          "name" => Autobot::Tools::PropertySchema.new(type: "string", description: "Name"),
        },
        required: ["name"]
      )

      errors = schema.validate({} of String => JSON::Any)
      errors.size.should eq(1)
      errors[0].should contain("missing required parameter 'name'")
    end

    it "passes with optional parameters omitted" do
      schema = Autobot::Tools::ToolSchema.new(
        properties: {
          "name"  => Autobot::Tools::PropertySchema.new(type: "string", description: "Name"),
          "label" => Autobot::Tools::PropertySchema.new(type: "string", description: "Label"),
        },
        required: ["name"]
      )

      errors = schema.validate({"name" => JSON::Any.new("test")})
      errors.should be_empty
    end
  end

  describe "#to_json_any" do
    it "converts schema to JSON::Any" do
      schema = Autobot::Tools::ToolSchema.new(
        properties: {
          "path" => Autobot::Tools::PropertySchema.new(type: "string", description: "File path"),
        },
        required: ["path"]
      )

      json = schema.to_json_any
      json["type"].as_s.should eq("object")
      json["properties"]["path"]["type"].as_s.should eq("string")
      json["required"].as_a.map(&.as_s).should eq(["path"])
    end
  end
end

# Simple tool for schema tests.
class SchemaDemoTool < Autobot::Tools::Tool
  def name : String
    "demo"
  end

  def description : String
    "A demo tool for testing schema output"
  end

  def parameters : Autobot::Tools::ToolSchema
    Autobot::Tools::ToolSchema.new(
      properties: {"input" => Autobot::Tools::PropertySchema.new(type: "string", description: "Input text")},
      required: ["input"],
    )
  end

  def execute(params : Hash(String, JSON::Any)) : Autobot::Tools::ToolResult
    Autobot::Tools::ToolResult.success("ok")
  end
end

describe "Tool#to_compact_schema" do
  it "omits description from compact schema" do
    tool = SchemaDemoTool.new
    schema = tool.to_compact_schema
    func = schema["function"]

    func["name"].as_s.should eq("demo")
    func["parameters"].should_not be_nil
    func["description"]?.should be_nil
  end

  it "includes full description in regular schema" do
    tool = SchemaDemoTool.new
    schema = tool.to_schema
    func = schema["function"]

    func["name"].as_s.should eq("demo")
    func["description"].as_s.should eq("A demo tool for testing schema output")
  end
end

describe Autobot::Tools::PropertySchema do
  describe "#validate" do
    it "validates string type" do
      prop = Autobot::Tools::PropertySchema.new(type: "string")
      prop.validate(JSON::Any.new("hello"), "field").should be_empty
    end

    it "rejects non-string for string type" do
      prop = Autobot::Tools::PropertySchema.new(type: "string")
      errors = prop.validate(JSON::Any.new(42_i64), "field")
      errors.size.should eq(1)
      errors[0].should contain("should be string")
    end

    it "validates integer type" do
      prop = Autobot::Tools::PropertySchema.new(type: "integer")
      prop.validate(JSON::Any.new(42_i64), "field").should be_empty
    end

    it "rejects non-integer for integer type" do
      prop = Autobot::Tools::PropertySchema.new(type: "integer")
      errors = prop.validate(JSON::Any.new("text"), "field")
      errors[0].should contain("should be integer")
    end

    it "validates boolean type" do
      prop = Autobot::Tools::PropertySchema.new(type: "boolean")
      prop.validate(JSON::Any.new(true), "field").should be_empty
    end

    it "validates array type" do
      prop = Autobot::Tools::PropertySchema.new(type: "array")
      prop.validate(JSON::Any.new([JSON::Any.new("a")]), "field").should be_empty
    end

    it "validates string min_length" do
      prop = Autobot::Tools::PropertySchema.new(type: "string", min_length: 3)
      errors = prop.validate(JSON::Any.new("ab"), "field")
      errors[0].should contain("at least 3 chars")
    end

    it "validates string max_length" do
      prop = Autobot::Tools::PropertySchema.new(type: "string", max_length: 5)
      errors = prop.validate(JSON::Any.new("toolong"), "field")
      errors[0].should contain("at most 5 chars")
    end

    it "validates enum_values" do
      prop = Autobot::Tools::PropertySchema.new(type: "string", enum_values: ["a", "b"])
      errors = prop.validate(JSON::Any.new("c"), "field")
      errors[0].should contain("must be one of")
    end

    it "validates integer minimum" do
      prop = Autobot::Tools::PropertySchema.new(type: "integer", minimum: 10_i64)
      errors = prop.validate(JSON::Any.new(5_i64), "field")
      errors[0].should contain(">= 10")
    end

    it "validates integer maximum" do
      prop = Autobot::Tools::PropertySchema.new(type: "integer", maximum: 100_i64)
      errors = prop.validate(JSON::Any.new(200_i64), "field")
      errors[0].should contain("<= 100")
    end

    it "validates array items" do
      item_schema = Autobot::Tools::PropertySchema.new(type: "string")
      prop = Autobot::Tools::PropertySchema.new(type: "array", items: item_schema)
      errors = prop.validate(JSON::Any.new([JSON::Any.new(42_i64)]), "field")
      errors[0].should contain("should be string")
    end
  end

  describe "#to_json_any" do
    it "includes type and description" do
      prop = Autobot::Tools::PropertySchema.new(type: "string", description: "A field")
      json = prop.to_json_any
      json["type"].as_s.should eq("string")
      json["description"].as_s.should eq("A field")
    end

    it "includes enum values" do
      prop = Autobot::Tools::PropertySchema.new(type: "string", enum_values: ["a", "b"])
      json = prop.to_json_any
      json["enum"].as_a.map(&.as_s).should eq(["a", "b"])
    end
  end
end
