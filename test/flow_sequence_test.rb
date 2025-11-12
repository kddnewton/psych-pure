# frozen_string_literal: true

require "test_helper"

module Psych
  module Pure
    class FlowSequenceTest < Minitest::Test
      def test_single_line_flow_array
        yaml = <<~YAML
          ---
          test: ['value1', 'value2']
        YAML

        result = Psych::Pure.load(yaml)
        assert_equal({ "test" => ["value1", "value2"] }, result)
      end

      def test_multi_line_flow_array
        yaml = <<~YAML
          ---
          test: [
            'value1',
            'value2'
          ]
        YAML

        result = Psych::Pure.load(yaml)
        assert_equal({ "test" => ["value1", "value2"] }, result)
      end

      def test_multi_line_flow_array_with_comment
        yaml = <<~YAML
          ---
          # Comment before
          test: [
            'value1',
            'value2'
          ]
        YAML

        result = Psych::Pure.load(yaml)
        assert_equal({ "test" => ["value1", "value2"] }, result)
      end

      def test_multi_line_flow_array_with_long_value
        yaml = <<~YAML
          ---
          config:
            # Comment before array
            keys: [
              'a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0u1v2w3x4y5z6a7b8c9d0e1f2'
            ]
        YAML

        result = Psych::Pure.load(yaml)
        assert_equal(
          {
            "config" => {
              "keys" => ["a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0u1v2w3x4y5z6a7b8c9d0e1f2"]
            }
          },
          result
        )
      end

      def test_round_trip_with_long_inline_array
        # Original YAML with inline flow array
        yaml = <<~YAML
          ---
          config:
            # Comment before array
            keys: ['a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0u1v2w3x4y5z6a7b8c9d0e1f2']
        YAML

        # Load with comments enabled
        loaded = Psych::Pure.load(yaml, comments: true)

        # Dump (may convert to multi-line)
        dumped = Psych::Pure.dump(loaded)

        # Should be able to reload
        reloaded = Psych::Pure.load(dumped, comments: true)

        # Compare the actual values
        assert_equal(
          { "config" => { "keys" => ["a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0u1v2w3x4y5z6a7b8c9d0e1f2"] } },
          loaded
        )
        assert_equal loaded, reloaded
      end

      def test_empty_flow_array
        yaml = <<~YAML
          ---
          test: []
        YAML

        result = Psych::Pure.load(yaml)
        assert_equal({ "test" => [] }, result)
      end

      def test_nested_flow_arrays
        yaml = <<~YAML
          ---
          test: [
            ['nested1', 'nested2'],
            ['nested3', 'nested4']
          ]
        YAML

        result = Psych::Pure.load(yaml)
        assert_equal(
          { "test" => [["nested1", "nested2"], ["nested3", "nested4"]] },
          result
        )
      end

      def test_flow_array_with_various_indentation
        # Closing bracket at different indentation levels
        yaml = <<~YAML
          ---
          test: [
            'value'
          ]
        YAML

        result = Psych::Pure.load(yaml)
        assert_equal({ "test" => ["value"] }, result)
      end
    end
  end
end
