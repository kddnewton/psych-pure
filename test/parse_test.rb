# frozen_string_literal: true

require "test_helper"

module Psych
  module Pure
    class ParseTest < Minitest::Test
      def test_alias
        assert_kind_of Nodes::Alias, parse("- &a 1\n- *a").children.last
      end

      def test_mapping_block
        assert_kind_of Nodes::Mapping, parse("a: 1")
      end

      def test_mapping_flow
        assert_kind_of Nodes::Mapping, parse("{a: 1}")
      end

      def test_scalar
        assert_kind_of Nodes::Scalar, parse("1")
      end

      def test_sequence_block
        assert_kind_of Nodes::Sequence, parse("- 1")
      end

      def test_sequence_flow
        assert_kind_of Nodes::Sequence, parse("[1]")
      end

      private

      def parse(source)
        Pure.parse(source).children[0]
      end
    end
  end
end
