# frozen_string_literal: true

require "test_helper"

module Psych
  module Pure
    class LoadedObjectTest < Minitest::Test
      def test_mutation
        result = Psych::Pure.load("foo: bar", comments: true)

        result["foo"].upcase!
        assert_predicate result["foo"], :dirty
        assert_equal "BAR", result["foo"]

        dumped = Psych::Pure.dump(result)
        assert_equal "---\nfoo: BAR\n", dumped
      end

      def test_query
        result = Psych::Pure.load("foo: bar", comments: true)

        result["foo"].length
        refute_predicate result["foo"], :dirty
      end
    end
  end
end
