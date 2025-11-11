# frozen_string_literal: true

require "test_helper"
require "yaml"

module Psych
  module Pure
    # Tests for LoadedHash mutation methods
    #
    # LoadedHash wraps a regular Hash and tracks keys with their comment metadata
    # in @psych_keys. When dumping, psych-pure uses @psych_keys (not the Hash keys)
    # to preserve comments.
    #
    # The bug: Hash mutation methods (delete, clear, etc.) were not updating @psych_keys,
    # causing deleted keys to reappear in the dump output.
    class LoadedHashTest < Minitest::Test
      def test_aset
        yaml = <<~YAML
          ---
          null: 1 # keep
          NULL: 2 # overwrite
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        data[nil] = 3 # overwrite the last key

        assert_equal 3, data[nil]
        assert_equal 2, data.psych_keys.length

        expected = <<~YAML
          ---
          null: 1 # keep
          NULL: 3
        YAML

        output = Psych::Pure.dump(data)
        assert_equal expected, output
      end

      def test_delete_removes_key_from_dump
        yaml = <<~YAML
          # Important key
          keep_me: value1
          # Will be deleted
          delete_me: value2
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        assert_equal ["keep_me", "delete_me"], data.keys

        # Delete a key
        result = data.delete("delete_me")
        assert_equal "value2", result
        assert_equal ["keep_me"], data.keys

        # Dump should NOT include the deleted key
        output = Psych::Pure.dump(data)
        refute_includes output, "delete_me"
        refute_includes output, "value2"
        assert_includes output, "keep_me"
        assert_includes output, "value1"

        # Verify comment is preserved for remaining key
        assert_includes output, "# Important key"
      end

      def test_delete_nonexistent_key
        yaml = "key: value"
        data = Psych::Pure.load(yaml, comments: true)

        result = data.delete("nonexistent")
        assert_nil result
        assert_equal ["key"], data.keys
      end

      def test_clear_removes_all_keys
        yaml = <<~YAML
          a: 1
          b: 2
          c: 3
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        data.clear

        assert_equal [], data.keys

        output = Psych::Pure.dump(data)
        # psych-pure formats empty hash as "--- {}" instead of "---\n{}\n"
        assert_match(/^---\s*\{\}\s*$/, output)
      end

      def test_shift_removes_first_key
        yaml = <<~YAML
          first: 1
          second: 2
          third: 3
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        key, value = data.shift

        assert_equal "first", key
        assert_equal 1, value
        assert_equal ["second", "third"], data.keys

        output = Psych::Pure.dump(data)
        refute_includes output, "first"
        assert_includes output, "second"
        assert_includes output, "third"
      end

      def test_delete_if_removes_matching_keys
        yaml = <<~YAML
          keep1: 10
          remove1: 5
          keep2: 20
          remove2: 3
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        data.delete_if { |k, v| v < 10 }

        assert_equal ["keep1", "keep2"], data.keys

        output = Psych::Pure.dump(data)
        assert_includes output, "keep1"
        assert_includes output, "keep2"
        refute_includes output, "remove1"
        refute_includes output, "remove2"
      end

      def test_keep_if_removes_non_matching_keys
        yaml = <<~YAML
          keep1: 10
          remove1: 5
          keep2: 20
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        data.keep_if { |k, v| v >= 10 }

        assert_equal ["keep1", "keep2"], data.keys

        output = Psych::Pure.dump(data)
        assert_includes output, "keep1"
        assert_includes output, "keep2"
        refute_includes output, "remove1"
      end

      def test_reject_bang_removes_matching_keys
        yaml = <<~YAML
          keep: good
          remove: bad
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        result = data.reject! { |k, v| v == "bad" }

        assert_equal data, result
        assert_equal ["keep"], data.keys

        output = Psych::Pure.dump(data)
        assert_includes output, "keep"
        refute_includes output, "remove"
      end

      def test_reject_bang_returns_nil_when_unchanged
        yaml = "keep: good"
        data = Psych::Pure.load(yaml, comments: true)

        result = data.reject! { |k, v| v == "bad" }
        assert_nil result
      end

      def test_select_bang_keeps_only_matching_keys
        yaml = <<~YAML
          keep: good
          remove: bad
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        result = data.select! { |k, v| v == "good" }

        assert_equal data, result
        assert_equal ["keep"], data.keys

        output = Psych::Pure.dump(data)
        assert_includes output, "keep"
        refute_includes output, "remove"
      end

      def test_delete_preserves_comments_on_remaining_keys
        yaml = <<~YAML
          # Comment for key1
          key1: value1
          # Comment for key2
          key2: value2
          # Comment for key3
          key3: value3
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        data.delete("key2")

        output = Psych::Pure.dump(data)

        # Comments for kept keys should be preserved
        assert_includes output, "# Comment for key1"
        assert_includes output, "# Comment for key3"

        # Deleted key and its comment should be gone
        refute_includes output, "key2"
        refute_includes output, "# Comment for key2"
      end

      def test_multiple_deletes
        yaml = <<~YAML
          a: 1
          b: 2
          c: 3
          d: 4
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        data.delete("b")
        data.delete("d")

        assert_equal ["a", "c"], data.keys

        output = Psych::Pure.dump(data)
        assert_includes output, "a: 1"
        assert_includes output, "c: 3"
        refute_includes output, "b:"
        refute_includes output, "d:"
      end

      def test_merge_bang_adds_keys
        yaml = <<~YAML
          # Original key
          a: 1
          b: 2
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        data.merge!({"c" => 3, "d" => 4})

        assert_equal ["a", "b", "c", "d"], data.keys

        output = Psych::Pure.dump(data)
        assert_includes output, "a: 1"
        assert_includes output, "c: 3"
        assert_includes output, "d: 4"
        assert_includes output, "# Original key"
      end

      def test_merge_bang_overwrites_existing_values
        yaml = <<~YAML
          # Original value
          a: 1
          b: 2
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        data.merge!({"a" => 999, "c" => 3})  # Overwrite 'a', add 'c'

        assert_equal 999, data["a"]
        assert_equal ["a", "b", "c"], data.keys

        output = Psych::Pure.dump(data)

        # Should have new value, not old
        assert_includes output, "a: 999"
        refute_includes output, "a: 1"

        # Comment should be preserved
        assert_includes output, "# Original value"

        # Verify semantics match
        reparsed = YAML.load(output)
        assert_equal 999, reparsed["a"]
      end

      def test_update_is_alias_of_merge
        yaml = "a: 1"
        data = Psych::Pure.load(yaml, comments: true)
        data.update({"b" => 2})

        assert_equal ["a", "b"], data.keys

        output = Psych::Pure.dump(data)
        assert_includes output, "a: 1"
        assert_includes output, "b: 2"
      end

      def test_replace_completely_replaces_hash
        yaml = <<~YAML
          a: 1
          b: 2
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        data.replace({"c" => 3, "d" => 4})

        assert_equal ["c", "d"], data.keys

        output = Psych::Pure.dump(data)
        refute_includes output, "a:"
        refute_includes output, "b:"
        assert_includes output, "c: 3"
        assert_includes output, "d: 4"
      end

      def test_compact_bang_removes_nil_values
        yaml = <<~YAML
          # Keep this
          keep: value
          # This will be nil
          remove: value
          # Keep this too
          keep2: value2
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        data["remove"] = nil
        result = data.compact!

        assert_equal data, result
        assert_equal ["keep", "keep2"], data.keys

        output = Psych::Pure.dump(data)
        assert_includes output, "keep: value"
        assert_includes output, "keep2: value2"
        refute_includes output, "remove:"
        # Comments for kept keys should remain
        assert_includes output, "# Keep this"
        assert_includes output, "# Keep this too"
      end

      def test_compact_bang_returns_nil_when_no_nils
        yaml = "a: 1\nb: 2"
        data = Psych::Pure.load(yaml, comments: true)

        result = data.compact!
        assert_nil result
        assert_equal ["a", "b"], data.keys
      end

      def test_compact_bang_removes_newly_added_nil
        yaml = "a: 1"
        data = Psych::Pure.load(yaml, comments: true)

        data["b"] = nil  # Add new key with nil value
        data.compact!

        assert_equal ["a"], data.keys

        output = Psych::Pure.dump(data)
        assert_includes output, "a: 1"
        refute_includes output, "b:"
      end
    end
  end
end
