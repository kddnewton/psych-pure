# frozen_string_literal: true

require "test_helper"

class TestParseContext < Minitest::Test
  def test_unclosed_flow_sequence_shows_context
    yaml = "servers: [a, b"
    
    error = assert_raises(Psych::SyntaxError) do
      Psych::Pure.load(yaml)
    end
    
    assert_includes error.message, "within:"
    assert_includes error.message, "flow sequence"
  end
  
  def test_unclosed_double_quoted_shows_context
    yaml = %q{config: "unclosed string}
    
    error = assert_raises(Psych::SyntaxError) do
      Psych::Pure.load(yaml)
    end
    
    assert_includes error.message, "within:"
    assert_includes error.message, "double quoted scalar"
  end
  
  def test_nested_structure_shows_full_context
    yaml = <<~YAML
      config:
        nested:
          value: \"unclosed
    YAML
    
    error = assert_raises(Psych::SyntaxError) do
      Psych::Pure.load(yaml)
    end
    
    assert_includes error.message, "within:"
    assert_includes error.message, "block mapping"
    assert_includes error.message, "double quoted scalar"
  end
end
