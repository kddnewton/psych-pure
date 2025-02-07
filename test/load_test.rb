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
  end
end
