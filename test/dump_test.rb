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

        def test_sequence_indent
          expected = <<~YAML
          ---
          a:
            - 1
            - 2
          YAML

          assert_equal(expected, dump({ "a" => [1, 2] }, sequence_indent: true))
        end

        private

        def dump(object, options = {})
          Pure.dump(object, options)
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

        def test_mapping_duplicate_keys
          expected = <<~YAML
          ---
          a: 1
          a: 2
          YAML

          assert_equal(expected, dump("a: 1\na: 2"))
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

        def test_sequence_block_comments
          expected = <<~YAML
          ---
          a:
          - 1
          # comment
          - 2
          YAML

          assert_equal(expected, dump(expected))
        end

        def test_sequence_flow
          expected = <<~YAML
          ---
          a: [1]
          YAML

          assert_equal(expected, dump("a: [1]"))
        end

        def test_sequence_indent
          expected = <<~YAML
          ---
          a:
            - 1
            - 2
          YAML

          assert_equal(expected, dump("a:\n- 1\n- 2", sequence_indent: true))
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

        def test_trailing_comments
          expected = <<~YAML
          ---
          a: 1 # inline
          YAML

          assert_equal(expected, dump(expected))
        end

        def test_leading_and_trailing_comments
          expected = <<~YAML
          # leading
          ---
          # before key
          a: 1
          YAML

          assert_equal(expected, dump(expected))
        end

        def test_trailing_block_comment
          expected = <<~YAML
          ---
          a: 1
          # trailing comment
          YAML

          assert_equal(expected, dump(expected))
        end

        def test_spaced_leading_comments
          expected = <<~YAML
          # comment 1
          ---
          # comment 2
          a: 1
          YAML

          assert_equal(expected, dump(expected))
        end

        private

        def dump(source, options = {})
          Pure.dump(
            Pure.load(source, aliases: true, permitted_classes: [Date, Time], comments: true),
            options
          )
        end
      end

      class DumpMultiDocumentTest < Minitest::Test
        def test_two_documents
          io = StringIO.new
          emitter = Pure::Emitter.new(io, {})
          emitter.emit("first")
          emitter.emit("second")

          assert_equal "--- first\n...\n--- second\n", io.string
        end
      end

      class SafeDumpTest < Minitest::Test
        def test_safe_dump_string
          result = Pure.safe_dump("hello")
          assert_equal "--- hello\n", result
        end

        def test_safe_dump_hash
          result = Pure.safe_dump("a" => 1)
          assert_equal "---\na: 1\n", result
        end

        def test_safe_dump_to_io
          io = StringIO.new
          Pure.safe_dump("hello", io)
          assert_equal "--- hello\n", io.string
        end

        def test_safe_dump_rejects_disallowed_class
          assert_raises(Psych::DisallowedClass) do
            Pure.safe_dump(Object.new)
          end
        end

        def test_safe_dump_with_permitted_classes
          result = Pure.safe_dump(:hello, permitted_classes: [Symbol], permitted_symbols: [:hello])
          assert_includes result, "hello"
        end

        def test_safe_dump_rejects_unpermitted_symbol
          assert_raises(Psych::DisallowedClass) do
            Pure.safe_dump(:secret, permitted_classes: [Symbol], permitted_symbols: [:allowed])
          end
        end

        def test_safe_dump_rejects_aliases
          inner = { "b" => 1 }
          obj = { "a" => inner, "c" => inner }

          assert_raises(Psych::BadAlias) do
            Pure.safe_dump(obj)
          end
        end

        def test_safe_dump_allows_aliases
          inner = { "b" => 1 }
          obj = { "a" => inner, "c" => inner }

          result = Pure.safe_dump(obj, aliases: true)
          assert_includes result, "&"
          assert_includes result, "*"
        end
      end

      class DumpNilTest < Minitest::Test
        def test_dump_nil
          result = Pure.dump(nil)
          assert_equal "---\n", result
        end

        def test_dump_nil_value
          result = Pure.dump("a" => nil)
          assert_equal "---\na:\n", result
        end
      end

      class DumpOmapTest < Minitest::Test
        def test_omap_roundtrip
          yaml = "--- !omap\n- a: 1\n- b: 2\n"
          loaded = Pure.load(yaml, comments: true)
          dumped = Pure.dump(loaded)

          assert_includes dumped, "!!omap"
          assert_includes dumped, "a: 1"
          assert_includes dumped, "b: 2"
        end
      end

      class DumpSetTest < Minitest::Test
        def test_set_roundtrip
          yaml = "--- !set\na:\nb:\n"
          loaded = Pure.load(yaml, permitted_classes: [Psych::Set], comments: true)
          dumped = Pure.dump(loaded)

          assert_includes dumped, "!set"
        end
      end

      class DumpMergeKeyTest < Minitest::Test
        def test_merge_key
          yaml = <<~YAML
            ---
            defaults: &defaults
              a: 1
              b: 2
            override:
              <<: *defaults
              b: 3
          YAML

          loaded = Pure.load(yaml, aliases: true, comments: true)
          assert_equal 1, loaded["override"]["a"]
          assert_equal 3, loaded["override"]["b"]
        end

        def test_merge_sequence
          yaml = <<~YAML
            ---
            h1: &h1
              a: 1
            h2: &h2
              b: 2
            merged:
              <<: [*h1, *h2]
              c: 3
          YAML

          loaded = Pure.load(yaml, aliases: true, comments: true)
          assert_equal 1, loaded["merged"]["a"]
          assert_equal 2, loaded["merged"]["b"]
          assert_equal 3, loaded["merged"]["c"]
        end
      end

      class DumpEscapeSequenceTest < Minitest::Test
        def test_hex_escape
          loaded = Pure.load("a: \"\\x41\"")
          assert_equal "A", loaded["a"]
        end

        def test_unicode_escape
          loaded = Pure.load("a: \"\\u0041\"")
          assert_equal "A", loaded["a"]
        end

        def test_long_unicode_escape
          loaded = Pure.load("a: \"\\U00000041\"")
          assert_equal "A", loaded["a"]
        end

        def test_hex_escape_with_comments
          loaded = Pure.load("a: \"\\x41\"", comments: true)
          assert_equal "A", loaded["a"]
        end

        def test_unicode_escape_with_comments
          loaded = Pure.load("a: \"\\u0041\"", comments: true)
          assert_equal "A", loaded["a"]
        end

        def test_long_unicode_escape_with_comments
          loaded = Pure.load("a: \"\\U00000041\"", comments: true)
          assert_equal "A", loaded["a"]
        end
      end

      class DumpComplexKeysTest < Minitest::Test
        def test_nil_key
          result = Pure.dump(nil => "value")
          assert_includes result, "! ''"
        end

        def test_multiline_string_key
          yaml = "? |\n  multi\n  line\n: value\n"
          loaded = Pure.load(yaml, comments: true)
          dumped = Pure.dump(loaded)

          assert_includes dumped, "?"
          assert_includes dumped, "value"
        end

        def test_complex_key
          yaml = "? [1, 2]\n: value\n"
          loaded = Pure.load(yaml, comments: true)
          dumped = Pure.dump(loaded)

          assert_includes dumped, "?"
          assert_includes dumped, "[1, 2]"
        end
      end

      class DumpTagsTest < Minitest::Test
        def test_tagged_string
          yaml = "---\na: !!str 123\n"
          loaded = Pure.load(yaml, comments: true)
          dumped = Pure.dump(loaded)

          assert_includes dumped, "!!str"
        end

        def test_tagged_int
          yaml = "---\na: !!int \"123\"\n"
          loaded = Pure.load(yaml, comments: true)
          dumped = Pure.dump(loaded)

          assert_includes dumped, "!!int"
        end
      end

      class DumpSymbolizeNamesTest < Minitest::Test
        def test_symbolize_names
          result = Pure.load("a: 1", symbolize_names: true)
          assert_equal({ a: 1 }, result)
        end

      end

      class DumpModifiedStringTest < Minitest::Test
        def test_mutated_string_dumps_new_value
          loaded = Pure.load("a: hello", comments: true)
          loaded["a"].replace("world")

          dumped = Pure.dump(loaded)
          assert_includes dumped, "world"
        end
      end

      class ParseErrorTest < Minitest::Test
        def test_non_string_raises_type_error
          assert_raises(TypeError) { Pure.parse(123) }
        end

        def test_non_utf8_raises_argument_error
          assert_raises(ArgumentError) { Pure.parse("x".encode("UTF-16LE")) }
        end
      end

      class DumpBlockScalarTest < Minitest::Test
        def test_literal_strip
          yaml = "---\na: |-\n  stripped\n"
          assert_equal(yaml, dump(yaml))
        end

        def test_literal_keep
          yaml = "---\na: |+\n  kept\n\n\n"
          assert_equal(yaml, dump(yaml))
        end

        def test_folded_clip
          yaml = "---\na: >\n  folded\n"
          assert_equal(yaml, dump(yaml))
        end

        def test_folded_strip
          yaml = "---\na: >-\n  stripped\n"
          assert_equal(yaml, dump(yaml))
        end

        def test_folded_keep
          yaml = "---\na: >+\n  kept\n\n\n"
          assert_equal(yaml, dump(yaml))
        end

        private

        def dump(source)
          Pure.dump(
            Pure.load(source, comments: true),
          )
        end
      end

      class DumpDocumentSuffixTest < Minitest::Test
        def test_document_suffix
          yaml = "---\na: 1\n...\n---\nb: 2\n"
          results = []
          Pure.parse_stream(yaml) { |node| results << node }
          assert_equal 2, results.length
        end
      end

      class DumpAnchoredArrayTest < Minitest::Test
        def test_anchored_array
          yaml = "---\na: &items\n- 1\n- 2\nb: *items\n"
          loaded = Pure.load(yaml, aliases: true, comments: true)
          dumped = Pure.dump(loaded)

          assert_includes dumped, "&"
          assert_includes dumped, "*"
        end

        def test_tagged_array
          yaml = "---\na: !!seq\n- 1\n- 2\n"
          loaded = Pure.load(yaml, comments: true)
          dumped = Pure.dump(loaded)

          assert_includes dumped, "!!seq"
        end
      end

      class DumpIndentEdgeCasesTest < Minitest::Test
        def test_indent_le_backtrack
          yaml = <<~YAML
            a:
              b: 1
            c: 2
          YAML

          loaded = Pure.load(yaml, comments: true)
          assert_equal 1, loaded["a"]["b"]
          assert_equal 2, loaded["c"]
        end

        def test_flow_in_context
          yaml = "{a: [1, 2], b: {c: 3}}\n"
          loaded = Pure.load(yaml, comments: true)
          assert_equal [1, 2], loaded["a"]
        end
      end

      class DumpMergeNonHashTest < Minitest::Test
        def test_merge_non_hash_alias
          yaml = <<~YAML
            ---
            a: &a [1, 2, 3]
            h:
              <<: *a
          YAML

          loaded = Pure.load(yaml, aliases: true, comments: true)
          assert_equal [1, 2, 3], loaded["h"]["<<"]
        end
      end

      class DumpInlinedHashKeyTest < Minitest::Test
        def test_inlined_array_value_after_complex_key
          yaml = "? [a, b]\n: [1, 2]\n"
          loaded = Pure.load(yaml, comments: true)
          dumped = Pure.dump(loaded)

          assert_includes dumped, "?"
        end

      end

      class DumpTrailingCommentsTest < Minitest::Test
        def test_non_inline_trailing_comment
          yaml = <<~YAML
            ---
            a: 1
            # after a
            b: 2
          YAML

          loaded = Pure.load(yaml, comments: true)
          dumped = Pure.dump(loaded)

          assert_includes dumped, "# after a"
        end

        def test_multi_trailing_comments_with_gap
          yaml = <<~YAML
            ---
            a: 1
            # trailing 1

            # trailing 2
            b: 2
          YAML

          loaded = Pure.load(yaml, comments: true)
          dumped = Pure.dump(loaded)

          assert_includes dumped, "# trailing 1"
          assert_includes dumped, "# trailing 2"
        end
      end

      class DumpMergeEdgeCasesTest < Minitest::Test
        def test_merge_with_scalar_value
          yaml = <<~YAML
            ---
            a:
              <<: literal_value
          YAML

          loaded = Pure.load(yaml, comments: true)
          assert_equal "literal_value", loaded["a"]["<<"]
        end
      end
    end
  end
end
