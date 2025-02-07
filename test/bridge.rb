# frozen_string_literal: true

require "psych/pure"

class TestML::Bridge
  class EventsHandler < Psych::Handler
    attr_reader :events

    def initialize
      @events = []
    end

    def alias(name)
      @events << "=ALI *#{name}\n".freeze
    end

    def start_document(version, tag_directives, implicit)
      parts = ["+DOC"]
      parts << "---" unless implicit
      @events << "#{parts.join(" ")}\n".freeze
    end

    def end_document(implicit)
      parts = ["-DOC"]
      parts << "..." unless implicit
      @events << "#{parts.join(" ")}\n".freeze
    end

    def start_mapping(anchor, tag, implicit, style)
      parts = ["+MAP"]
      parts << "{}" if style == Psych::Nodes::Mapping::FLOW
      parts << "&#{anchor}" if anchor
      parts << "<#{tag}>" if tag
      @events << "#{parts.join(" ")}\n".freeze
    end

    def end_mapping
      @events << "-MAP\n"
    end

    def scalar(value, anchor, tag, plain, quoted, style)
      parts = ["=VAL"]
      parts << "&#{anchor}" if anchor
      parts << "<#{tag}>" if tag

      prefix =
        case style
        when Psych::Nodes::Scalar::PLAIN then ":"
        when Psych::Nodes::Scalar::SINGLE_QUOTED then "'"
        when Psych::Nodes::Scalar::DOUBLE_QUOTED then '"'
        when Psych::Nodes::Scalar::LITERAL then "|"
        when Psych::Nodes::Scalar::FOLDED then ">"
        else raise InternalError, style.inspect
        end

      parts << "#{prefix}#{escape_scalar_value(value)}"
      @events << "#{parts.join(" ")}\n".freeze
    end

    def start_sequence(anchor, tag, implicit, style)
      parts = ["+SEQ"]
      parts << "[]" if style == Psych::Nodes::Sequence::FLOW
      parts << "&#{anchor}" if anchor
      parts << "<#{tag}>" if tag
      @events << "#{parts.join(" ")}\n".freeze
    end

    def end_sequence
      @events << "-SEQ\n"
    end

    def start_stream(encoding)
      @events << "+STR\n"
    end

    def end_stream
      @events << "-STR\n"
    end

    private

    def escape_scalar_value(value)
      value = value.dup
      value.gsub!(/\\/, '\\\\\\\\')
      value.gsub!(/\x00/, '\\0')
      value.gsub!(/\x07/, '\\a')
      value.gsub!(/\x08/, '\\b')
      value.gsub!(/\x09/, '\\t')
      value.gsub!(/\x0a/, '\\n')
      value.gsub!(/\x0b/, '\\v')
      value.gsub!(/\x0c/, '\\f')
      value.gsub!(/\x0d/, '\\r')
      value.gsub!(/\x1b/, '\\e')
      value.gsub!(/\u{85}/, '\\N')
      value.gsub!(/\u{a0}/, '\\_')
      value.gsub!(/\u{2028}/, '\\L')
      value.gsub!(/\u{2029}/, '\\P')
      value
    end
  end

  def parse(source, expect_error = false)
    handler = EventsHandler.new
    Psych::Pure::Parser.new(handler).parse(source)
    expect_error ? 0 : handler.events.join
  rescue Psych::SyntaxError => error
    expect_error ? 1 : error.message
  end

  def unescape(source)
    source
      .gsub(/␣/, " ")
      .gsub(/—*»/, "\t")
      .gsub(/⇔/, "\uFEFF")
      .gsub(/↵/, "")
      .gsub(/∎\n$/, "")
  end

  def fix_test_output(source)
    source
  end
end
