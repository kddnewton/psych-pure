# frozen_string_literal: true

require "test_helper"

module Psych
  module Pure
    class LoadTest < Minitest::Test
      def test_alias
        assert_equal [1, 1], load("- &a 1\n- *a\n")
      end

      def test_mapping_block
        assert_equal({"a" => 1}, load("a: 1"))
      end

      def test_mapping_flow
        assert_equal({"a" => 1}, load("{a: 1}"))
      end

      def test_scalar
        assert_equal 1, load("1")
      end

      def test_sequence_block
        assert_equal [1], load("- 1")
      end

      def test_sequence_flow
        assert_equal [1], load("[1]")
      end

      private

      def load(source)
        Pure.load(source, aliases: true)
      end
    end

    class UnsafeLoadTest < Minitest::Test
      def test_basic
        assert_equal 1, Pure.unsafe_load("1")
      end

      def test_fallback
        assert_equal "default", Pure.unsafe_load("", fallback: "default")
      end
    end

    class LoadStreamTest < Minitest::Test
      def test_with_block
        yaml = "---\na: 1\n---\nb: 2\n"
        results = []
        Pure.load_stream(yaml) { |doc| results << doc }

        assert_equal 2, results.length
        assert_equal({"a" => 1}, results[0])
        assert_equal({"b" => 2}, results[1])
      end
    end

    class FileLoadTest < Minitest::Test
      def setup
        @tmpfile = File.join(Dir.tmpdir, "psych_pure_test_#{$$}.yml")
        File.write(@tmpfile, "a: 1\n")
      end

      def teardown
        File.delete(@tmpfile) if File.exist?(@tmpfile)
      end

      def test_load_file
        result = Pure.load_file(@tmpfile)
        assert_equal({"a" => 1}, result)
      end

      def test_safe_load_file
        result = Pure.safe_load_file(@tmpfile)
        assert_equal({"a" => 1}, result)
      end

      def test_unsafe_load_file
        result = Pure.unsafe_load_file(@tmpfile)
        assert_equal({"a" => 1}, result)
      end

      def test_parse_file
        result = Pure.parse_file(@tmpfile)
        assert_kind_of Psych::Nodes::Document, result
      end

      def test_parse_file_fallback
        empty_file = File.join(Dir.tmpdir, "psych_pure_empty_#{$$}.yml")
        File.write(empty_file, "")

        result = Pure.parse_file(empty_file, fallback: :none)
        assert_equal :none, result
      ensure
        File.delete(empty_file) if File.exist?(empty_file)
      end
    end
  end
end
