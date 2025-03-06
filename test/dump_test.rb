# frozen_string_literal: true

require "test_helper"

module Psych
  module Pure
    module DumpTest
      class DumpObjectsTest < Minitest::Test
        def test_alias
          expected = <<~YAML
          ---
          a: &1
            b: 1
          c: *1
          YAML

          inner = { "b" => 1 }
          assert_equal(expected, dump("a" => inner, "c" => inner))
        end

        def test_mapping_non_empty
          expected = <<~YAML
          ---
          a:
            b: 1
          YAML

          assert_equal(expected, dump("a" => { "b" => 1 }))
        end

        def test_mapping_empty
          expected = <<~YAML
          ---
          a: {}
          YAML

          assert_equal(expected, dump("a" => {}))
        end

        def test_sequence_non_empty
          expected = <<~YAML
          ---
          a:
          - 1
          YAML

          assert_equal(expected, dump("a" => [1]))
        end

        def test_sequence_empty
          expected = <<~YAML
          ---
          a: []
          YAML

          assert_equal(expected, dump("a" => []))
        end

        private

        def dump(object)
          Pure.dump(object)
        end
      end

      class DumpLoadedTest < Minitest::Test
        def test_alias
          expected = <<~YAML
          ---
          a: &anchor
            b: 1
          c: *anchor
          YAML

          assert_equal(expected, dump(expected))
        end

        def test_mapping_block
          expected = <<~YAML
          ---
          a:
            b: 1
          YAML

          assert_equal(expected, dump("a:\n  b: 1"))
        end

        def test_mapping_flow
          expected = <<~YAML
          ---
          a: { b: 1 }
          YAML

          assert_equal(expected, dump("a: {b: 1}"))
        end

        def test_scalar_true
          assert_equal(
            "---\n[true, True, TRUE, yes, Yes, YES, on, On, ON]\n",
            dump("[true, True, TRUE, yes, Yes, YES, on, On, ON]")
          )
        end

        def test_scalar_false
          assert_equal(
            "---\n[false, False, FALSE, no, No, NO, off, Off, OFF]\n",
            dump("[false, False, FALSE, no, No, NO, off, Off, OFF]")
          )
        end

        def test_scalar_numbers
          expected = <<~YAML
          ---
          a: 42
          b: -17
          c: 3.14159
          d: 12.3e+02
          e: 0
          f: .inf
          g: -.inf
          h: .nan
          i: 0o14
          j: 0xC
          k: 0b1010
          l: 190:20:30
          YAML

          assert_equal(expected, dump(expected))
        end

        def test_scalar_times
          expected = <<~YAML
          ---
          a: 2023-12-25
          b: 2023-12-25T14:30:00.123Z
          c: 2023-12-25 14:30:00.123
          d: 2023-12-25T14:30:00.123+02:00
          e: 2023-12-25T14:30:00.123-05:00
          YAML

          assert_equal(expected, dump(expected))
        end

        def test_sequence_block
          expected = <<~YAML
          ---
          a:
          - 1
          YAML

          assert_equal(expected, dump("a:\n- 1"))
        end

        def test_sequence_flow
          expected = <<~YAML
          ---
          a: [1]
          YAML

          assert_equal(expected, dump("a: [1]"))
        end

        def test_string_literal_block
          expected = <<~YAML
          ---
          literal_block: \|
            Line 1
            Line 2
            Line 3
          YAML

          assert_equal(expected, dump(expected))
        end

        def test_string_literal_strip
          expected = <<~YAML
          ---
          literal_strip: \|-
            Remove trailing newlines
            from this block
          YAML

          assert_equal(expected, dump(expected))
        end

        def test_string_literal_keep_zero
          expected = <<~YAML
          ---
          literal_keep: \|+
            Keep trailing newlines
            in this block
          YAML

          assert_equal(expected, dump(expected))
        end

        def test_string_literal_keep_one
          expected = <<~YAML
          ---
          literal_keep: \|+
            Keep trailing newlines
            in this block
          YAML

          assert_equal(expected, dump(expected))
        end

        def test_string_literal_keep_many
          expected = "---\nliteral_keep: \|+\n  Keep trailing newlines\n  in this block\n\n\n\n"
          assert_equal(expected, dump(expected))
        end

        private

        def dump(source)
          Pure.dump(Pure.load(source, aliases: true, permitted_classes: [Date, Time], comments: true))
        end
      end
    end
  end
end
