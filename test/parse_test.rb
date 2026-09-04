# frozen_string_literal: true

require "test_helper"

module Psych
  module Pure
    class ParseTest < Minitest::Test
      base = File.expand_path("../tmp/yaml-test-suite/src", __dir__)
      empty = %w[QT73.yaml AVM7.yaml 8G76.yaml HWV9.yaml 98YD.yaml]

      Dir["*.yaml", base: base].each do |filename|
        next if empty.include?(filename)

        fixture = Psych::Pure.load(File.read(File.join(base, filename)))[0]
        next if fixture["skip"] || fixture["fail"]

        source = +fixture["yaml"]
        source.gsub!(/␣/, " ")
        source.gsub!(/—*»/, "\t")
        source.gsub!(/⇔/, "\uFEFF")
        source.gsub!(/↵/, "")
        source.gsub!(/∎\n$/, "")

        define_method(:"test_#{File.basename(filename, ".yaml")}") do
          assert_kind_of(Nodes::Document, Psych::Pure.parse(source))
        end
      end

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

      def test_multibyte_start_lines
        source = <<~YAML
          名前: 山田太郎
          挨拶: こんにちは
          住所: 東京都
        YAML
        nodes = parse(source).children

        assert_equal [0, 0, 1, 1, 2, 2], nodes.map(&:start_line)
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
