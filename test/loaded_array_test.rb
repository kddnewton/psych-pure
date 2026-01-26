# frozen_string_literal: true

require "test_helper"
require "yaml"

module Psych
  module Pure
    # Tests for LoadedArray mutation methods
    #
    # LoadedArray wraps a regular Array and tracks elements with their comment metadata
    # in @psych_elements. When dumping, psych-pure uses @psych_elements (not the Array elements)
    # to preserve comments.
    #
    # The bug: Array mutation methods (delete, reject!, etc.) were not updating @psych_elements,
    # causing deleted elements to reappear in the dump output, or worse, leaving blank lines
    # where deleted elements used to be.
    class LoadedArrayTest < Minitest::Test
      def test_class
        yaml = <<~YAML
          - alpha
          - beta
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        assert_instance_of Psych::Pure::LoadedArray, data
      end

      def test_delete_removes_element_from_dump
        yaml = <<~YAML
          - keep_me
          - delete_me
          - also_keep
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        assert_equal ["keep_me", "delete_me", "also_keep"], data.to_a

        # Delete an element
        result = data.delete("delete_me")
        assert_equal "delete_me", result
        assert_equal ["keep_me", "also_keep"], data.to_a

        # Dump should NOT include the deleted element
        output = Psych::Pure.dump(data)
        refute_includes output, "delete_me"
        assert_includes output, "keep_me"
        assert_includes output, "also_keep"
      end

      def test_delete_nonexistent_element
        yaml = "- item"
        data = Psych::Pure.load(yaml, comments: true)

        result = data.delete("nonexistent")
        assert_nil result
        assert_equal ["item"], data.to_a
      end

      def test_reject_removes_matching_elements
        yaml = <<~YAML
          - alpha
          - beta
          - gamma
          - delta
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        data.reject! { |item| item == "beta" }

        assert_equal ["alpha", "gamma", "delta"], data.to_a

        output = Psych::Pure.dump(data)
        assert_includes output, "alpha"
        refute_includes output, "beta"
        assert_includes output, "gamma"
        assert_includes output, "delta"
      end

      def test_reject_no_blank_lines
        yaml = <<~YAML
          - alpha
          - beta
          - gamma
          - delta
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        data.reject! { |item| item == "beta" }

        output = Psych::Pure.dump(data)
        refute_includes output, "\n\n", "Output should not contain blank lines"
      end

      def test_delete_at
        yaml = <<~YAML
          - first
          - second
          - third
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        result = data.delete_at(1)

        assert_equal "second", result
        assert_equal ["first", "third"], data.to_a

        output = Psych::Pure.dump(data)
        assert_includes output, "first"
        refute_includes output, "second"
        assert_includes output, "third"
        refute_includes output, "\n\n"
      end

      def test_pop
        yaml = <<~YAML
          - first
          - second
          - third
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        result = data.pop

        assert_equal "third", result
        assert_equal ["first", "second"], data.to_a

        output = Psych::Pure.dump(data)
        assert_includes output, "first"
        assert_includes output, "second"
        refute_includes output, "third"
      end

      def test_shift
        yaml = <<~YAML
          - first
          - second
          - third
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        result = data.shift

        assert_equal "first", result
        assert_equal ["second", "third"], data.to_a

        output = Psych::Pure.dump(data)
        refute_includes output, "first"
        assert_includes output, "second"
        assert_includes output, "third"
        refute_includes output, "\n\n"
      end

      def test_clear
        yaml = <<~YAML
          - a
          - b
          - c
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        data.clear

        assert_equal [], data.to_a

        output = Psych::Pure.dump(data)
        assert_match(/^---\s*\[\]\s*$/, output)
      end

      def test_keep_if
        yaml = <<~YAML
          - small
          - medium
          - large
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        data.keep_if { |item| item.length >= 5 }

        assert_equal ["small", "medium", "large"], data.to_a

        output = Psych::Pure.dump(data)
        refute_includes output, "\n\n"
      end

      def test_slice
        yaml = <<~YAML
          - first
          - second
          - third
          - fourth
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        removed = data.slice!(1, 2)

        assert_equal ["second", "third"], removed.to_a
        assert_equal ["first", "fourth"], data.to_a

        output = Psych::Pure.dump(data)
        assert_includes output, "first"
        refute_includes output, "second"
        refute_includes output, "third"
        assert_includes output, "fourth"
        refute_includes output, "\n\n"
      end

      def test_uniq
        yaml = <<~YAML
          - alpha
          - beta
          - alpha
          - gamma
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        data.uniq!

        assert_equal ["alpha", "beta", "gamma"], data.to_a

        output = Psych::Pure.dump(data)
        refute_includes output, "\n\n"
      end

      def test_compact
        yaml = <<~YAML
          - alpha
          - null
          - gamma
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        data.compact!

        assert_equal ["alpha", "gamma"], data.to_a

        output = Psych::Pure.dump(data)
        assert_includes output, "alpha"
        assert_includes output, "gamma"
        refute_includes output, "\n\n"
      end

      def test_delete_if
        yaml = <<~YAML
          - keep1
          - remove1
          - keep2
          - remove2
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        data.delete_if { |item| item.start_with?("remove") }

        assert_equal ["keep1", "keep2"], data.to_a

        output = Psych::Pure.dump(data)
        assert_includes output, "keep1"
        assert_includes output, "keep2"
        refute_includes output, "remove1"
        refute_includes output, "remove2"
        refute_includes output, "\n\n"
      end

      def test_preserves_comments_on_remaining_elements
        yaml = <<~YAML
          # First element comment
          - alpha
          # Second element comment (will be deleted)
          - beta
          # Third element comment
          - gamma
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        data.delete("beta")

        output = Psych::Pure.dump(data)
        assert_includes output, "# First element comment"
        refute_includes output, "# Second element comment"
        assert_includes output, "# Third element comment"
      end

      def test_dirty_flag_set_on_deletion
        yaml = <<~YAML
          - alpha
          - beta
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        refute data.dirty, "Array should not be dirty initially"

        data.delete("beta")
        assert data.dirty, "Array should be dirty after deletion"
      end

      def test_dirty_flag_not_set_on_push
        yaml = <<~YAML
          - alpha
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        data << "beta"

        refute data.dirty, "Array should not be dirty after push"
      end

      def test_preserves_blank_lines_when_not_mutated
        yaml = <<~YAML
          - alpha

          - gamma
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        # No mutations, just dump

        output = Psych::Pure.dump(data)
        assert_includes output, "\n\n", "Should preserve intentional blank lines"
      end

      def test_removes_blank_lines_when_mutated
        yaml = <<~YAML
          - alpha

          - beta

          - gamma
        YAML

        data = Psych::Pure.load(yaml, comments: true)
        data.delete("beta")

        output = Psych::Pure.dump(data)
        refute_includes output, "\n\n", "Should not preserve blank lines after mutation"
      end
    end
  end
end
