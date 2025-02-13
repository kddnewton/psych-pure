# frozen_string_literal: true

require "delegate"
require "pp"
require "psych"
require "strscan"
require "stringio"

module Psych
  # A YAML parser written in Ruby.
  module Pure
    # An internal exception is an exception that should not have occurred. It is
    # effectively an assertion.
    class InternalException < Exception
      def initialize(message = "An internal exception occurred")
        super(message)
      end
    end

    # A source is wraps the input string and provides methods to access line and
    # column information from a byte offset.
    class Source
      def initialize(string)
        @line_offsets = []
        @trimmable_lines = []

        offset = 0
        string.each_line do |line|
          @line_offsets << offset
          @trimmable_lines << line.match?(/\A(?: *#.*)?\n\z/)
          offset += line.bytesize
        end

        @line_offsets << offset
        @trimmable_lines << true
      end

      def trim(offset)
        while (l = line(offset)) != 0 && (offset == @line_offsets[l]) && @trimmable_lines[l - 1]
          offset = @line_offsets[l - 1]
        end

        offset
      end

      def line(offset)
        index = @line_offsets.bsearch_index { |line_offset| line_offset > offset }
        return @line_offsets.size - 1 if index.nil?
        index - 1
      end

      def column(offset)
        offset - @line_offsets[line(offset)]
      end
    end

    # A location represents a range of bytes in the input string.
    class Location
      protected attr_reader :pos_end

      def initialize(source, pos_start, pos_end)
        @source = source
        @pos_start = pos_start
        @pos_end = pos_end
      end

      def start_line
        @source.line(@pos_start)
      end

      def start_column
        @source.column(@pos_start)
      end

      def end_line
        @source.line(@pos_end)
      end

      def end_column
        @source.column(@pos_end)
      end

      def join(other)
        @pos_end = other.pos_end
      end

      # Trim trailing whitespace and comments from this location.
      def trim
        Location.new(@source, @pos_start, @source.trim(@pos_end))
      end

      def to_a
        [start_line, start_column, end_line, end_column]
      end

      def self.point(source, pos)
        new(source, pos, pos)
      end
    end

    # Represents a comment in the input.
    class Comment
      attr_reader :location, :value

      def initialize(location, value, inline)
        @location = location
        @value = value
        @inline = inline
      end

      def inline?
        @inline
      end

      def start_line
        location.start_line
      end

      def start_column
        location.start_column
      end

      def end_line
        location.end_line
      end

      def end_column
        location.end_column
      end
    end

    # Represents the set of comments on a node.
    class Comments
      attr_reader :leading, :trailing

      def initialize
        @leading = []
        @trailing = []
      end

      def leading_comment(comment)
        @leading << comment
      end

      def trailing_comment(comment)
        @trailing << comment
      end
    end

    # Wraps a Ruby object with its comments from the source input.
    class CommentsObject < SimpleDelegator
      attr_reader :psych_comments

      def initialize(object, psych_comments)
        @psych_comments = psych_comments
        super(object)
      end
    end

    # Wraps a Ruby hash with its comments from the source input.
    class CommentsHash < SimpleDelegator
      attr_reader :psych_comments, :psych_key_comments

      def initialize(object, psych_comments, psych_key_comments = {})
        @psych_comments = psych_comments
        @psych_key_comments = psych_key_comments
        commentless = {}

        object.each do |key, value|
          if key.is_a?(CommentsObject)
            @psych_key_comments[key.__getobj__] = key.psych_comments
            commentless[key.__getobj__] = value
          else
            commentless[key] = value
          end
        end

        super(commentless)
      end

      def []=(key, value)
        if (previous = self[key])
          if previous.is_a?(CommentsObject)
            value = CommentsObject.new(value, previous.psych_comments)
          elsif previous.is_a?(CommentsHash)
            value = CommentsHash.new(value, previous.psych_comments, previous.psych_key_comments)
          end
        end

        super(key, value)
      end
    end

    # This module contains all of the extensions to Psych that we need in order
    # to support parsing comments.
    module CommentExtensions
      # Extend the Handler to be able to handle comments coming out of the
      # parser.
      module Handler
        def comment(value)
        end
      end

      # Extend the TreeBuilder to be able to attach comments to nodes.
      module TreeBuilder
        def comments
          @comments ||= []
        end

        def comment(value)
          comments << value
        end

        def end_stream
          attach_comments(super)
        end

        private

        def attach_comments(node)
          comments.each do |comment|
            preceding, enclosing, following = nearest_nodes(node, comment)

            if comment.inline?
              if preceding
                preceding.trailing_comment(comment)
              else
                (following || enclosing || node).leading_comment(comment)
              end
            else
              # If a comment exists on its own line, prefer a leading comment.
              if following
                following.leading_comment(comment)
              elsif preceding
                preceding.trailing_comment(comment)
              else
                (enclosing || node).leading_comment(comment)
              end
            end
          end

          comments.clear
          node
        end

        def nearest_nodes(node, comment)
          candidates = (node.children || []).sort_by { |child| [child.start_line, child.start_column] }
          preceding = nil
          following = nil

          location = comment.location
          comment_start_line = location.start_line
          comment_start_column = location.start_column
          comment_end_line = location.end_line
          comment_end_column = location.end_column

          left = 0
          right = candidates.length

          # This is a custom binary search that finds the nearest nodes to the
          # given comment. When it finds a node that completely encapsulates the
          # comment, it recurses downward into the tree.
          while left < right
            middle = (left + right) / 2
            candidate = candidates[middle]

            if ((comment_start_line > candidate.start_line) || (comment_start_line == candidate.start_line && comment_start_column >= candidate.start_column)) &&
               ((comment_end_line < candidate.end_line) || (comment_end_line == candidate.end_line && comment_end_column <= candidate.end_column))
              # The comment is completely contained by this candidate node.
              # Abandon the binary search at this level.
              return nearest_nodes(candidate, comment)
            end

            if (candidate.end_line < comment_start_line) ||
               (candidate.end_line == comment_start_line && candidate.end_column <= comment_start_column)
              # This candidate falls completely before the comment. Because we
              # will never consider this candidate or any candidates before it
              # again, this candidate must be the closest preceding candidate we
              # have encountered so far.
              preceding = candidate
              left = middle + 1
              next
            end

            if (candidate.start_line > comment_end_line) ||
               (candidate.start_line == comment_end_line && candidate.start_column >= comment_end_column)
              # This candidate falls completely after the comment. Because we
              # will never consider this candidate or any candidates after it
              # again, this candidate must be the closest following candidate we
              # have encountered so far.
              following = candidate
              right = middle
              next
            end

            # This should only happen if there is a bug in this parser.
            raise InternalException, "Comment location overlaps with a target location"
          end

          [preceding, node, following]
        end
      end

      # Extend the document stream to be able to attach comments to the
      # document.
      module DocumentStream
        def end_document(implicit_end = !streaming?)
          @last.implicit_end = implicit_end
          @block.call(attach_comments(pop))
        end
      end

      # Extend the nodes to be able to store comments.
      module Node
        def leading_comment(comment)
          comments.leading_comment(comment)
        end

        def trailing_comment(comment)
          comments.trailing_comment(comment)
        end

        def comments
          @comments ||= Comments.new
        end

        def comments?
          defined?(@comments)
        end

        def to_ruby(symbolize_names: false, freeze: false, strict_integer: false, comments: false)
          Visitors::ToRuby.create(symbolize_names: symbolize_names, freeze: freeze, strict_integer: strict_integer, comments: comments).accept(self)
        end
      end

      # Extend the ToRuby visitor to be able to attach comments to the resulting
      # Ruby objects.
      module ToRuby
        attr_reader :comments

        def initialize(ss, class_loader, symbolize_names: false, freeze: false, comments: false)
          super(ss, class_loader, symbolize_names: symbolize_names, freeze: freeze)
          @comments = comments
        end

        def accept(node)
          result = super

          if @comments
            if result.is_a?(Hash)
              result = CommentsHash.new(result, node.comments? ? node.comments : nil)
            elsif node.comments?
              result = CommentsObject.new(result, node.comments)
            end
          end

          result
        end
      end

      # Extend the ToRuby singleton to be able to pass the comments option.
      module ToRubySingleton
        def create(symbolize_names: false, freeze: false, strict_integer: false, comments: false)
          class_loader = ClassLoader.new
          scanner      = ScalarScanner.new(class_loader, strict_integer: strict_integer)
          new(scanner, class_loader, symbolize_names: symbolize_names, freeze: freeze, comments: comments)
        end
      end
    end

    ::Psych::Handler.prepend(CommentExtensions::Handler)
    ::Psych::TreeBuilder.prepend(CommentExtensions::TreeBuilder)
    ::Psych::Handlers::DocumentStream.prepend(CommentExtensions::DocumentStream)
    ::Psych::Nodes::Node.prepend(CommentExtensions::Node)
    ::Psych::Visitors::ToRuby.prepend(CommentExtensions::ToRuby)
    ::Psych::Visitors::ToRuby.singleton_class.prepend(CommentExtensions::ToRubySingleton)

    # An alias event represents a reference to a previously defined anchor.
    class Alias
      attr_reader :location, :name

      def initialize(location, name)
        @location = location
        @name = name
      end

      def accept(handler)
        handler.event_location(*@location)
        handler.alias(@name)
      end
    end

    # A document start event represents the beginning of a new document, of
    # which there can be multiple in a single YAML stream.
    class DocumentStart
      attr_reader :location, :tag_directives
      attr_accessor :version
      attr_writer :implicit

      def initialize(location)
        @location = location
        @version = nil
        @tag_directives = {}
        @implicit = true
      end

      def accept(handler)
        handler.event_location(*@location)
        handler.start_document(@version, @tag_directives.to_a, @implicit)
      end
    end

    # A document end event represents the end of a document, which may be
    # implicit at the end of the stream or explicit with the ... delimiter.
    class DocumentEnd
      attr_reader :location
      attr_writer :implicit

      def initialize(location)
        @location = location
        @implicit = true
      end

      def accept(handler)
        handler.event_location(*@location)
        handler.end_document(@implicit)
      end
    end

    # A mapping start event represents the beginning of a new mapping, which is
    # a set of key-value pairs.
    class MappingStart
      attr_reader :location, :style
      attr_accessor :anchor, :tag

      def initialize(location, style)
        @location = location
        @anchor = nil
        @tag = nil
        @style = style
      end

      def accept(handler)
        handler.event_location(*@location)
        handler.start_mapping(@anchor, @tag, @style == Nodes::Mapping::BLOCK, @style)
      end
    end

    # A mapping end event represents the end of a mapping.
    class MappingEnd
      attr_reader :location

      def initialize(location)
        @location = location
      end

      def accept(handler)
        handler.event_location(*@location.trim)
        handler.end_mapping
      end
    end

    # A scalar event represents a single value in the YAML document. It can be
    # many different types.
    class Scalar
      attr_reader :location, :value, :style
      attr_accessor :anchor, :tag

      def initialize(location, value, style)
        @location = location
        @value = value
        @anchor = nil
        @tag = nil
        @style = style
      end

      def accept(handler)
        handler.event_location(*@location)
        handler.scalar(
          @value,
          @anchor,
          @tag,
          (!@tag || @tag == "!") && (@style == Nodes::Scalar::PLAIN),
          (!@tag || @tag == "!") && (@style != Nodes::Scalar::PLAIN),
          @style
        )
      end
    end

    # A sequence start event represents the beginning of a new sequence, which
    # is a list of values.
    class SequenceStart
      attr_reader :location, :style
      attr_accessor :anchor, :tag

      def initialize(location, style)
        @location = location
        @anchor = nil
        @tag = nil
        @style = style
      end

      def accept(handler)
        handler.event_location(*@location)
        handler.start_sequence(@anchor, @tag, @style == Nodes::Sequence::BLOCK, @style)
      end
    end

    # A sequence end event represents the end of a sequence.
    class SequenceEnd
      attr_reader :location

      def initialize(location)
        @location = location
      end

      def accept(handler)
        handler.event_location(*@location.trim)
        handler.end_sequence
      end
    end

    # A stream start event represents the beginning of a new stream. There
    # should only be one of these in a YAML stream.
    class StreamStart
      attr_reader :location

      def initialize(location)
        @location = location
      end

      def accept(handler)
        handler.event_location(*@location)
        handler.start_stream(Psych::Parser::UTF8)
      end
    end

    # A stream end event represents the end of a stream. There should only be
    # one of these in a YAML stream.
    class StreamEnd
      attr_reader :location

      def initialize(location)
        @location = location
      end

      def accept(handler)
        handler.event_location(*@location)
        handler.end_stream
      end
    end

    # The parser is responsible for taking a YAML string and converting it into
    # a series of events that can be used by the consumer.
    class Parser
      # Initialize a new parser with the given source string.
      def initialize(handler)
        # These are used to track the current state of the parser.
        @scanner = nil
        @filename = nil
        @source = nil

        # The handler is the consumer of the events generated by the parser.
        @handler = handler

        # This functions as a list of temporary lists of events that may be
        # flushed into the handler if current context is matched.
        @events_cache = []

        # These events are used to track the start and end of a document. They
        # are flushed into the main events list when a new document is started.
        @document_start_event = nil
        @document_end_event = nil

        # Each document gets its own set of tags. This is a mapping of tag
        # handles to tag prefixes.
        @tag_directives = nil

        # When a tag property is parsed, it is stored here until it can be
        # flushed into the next event.
        @tag = nil

        # When an anchor is parsed, it is stored here until it can be flushed
        # into the next event.
        @anchor = nil

        # In a bare document, explicit document starts (---) and ends (...) are
        # disallowed. In that case we need to check for those delimiters.
        @in_bare_document = false

        # In a literal or folded scalar, we need to track that state in order to
        # insert the correct plain text prefix.
        @in_scalar = false
        @text_prefix = +""

        # This parser can optionally parse comments and attach them to the
        # resulting tree, if the option is passed.
        @comments = nil
      end

      # Top-level parse function that starts the parsing process.
      def parse(yaml, filename = yaml.respond_to?(:path) ? yaml.path : "<unknown>", comments: false)
        if yaml.respond_to?(:read)
          yaml = yaml.read
        elsif !yaml.is_a?(String)
          raise TypeError, "Expected an IO or a String, got #{yaml.class}"
        end

        # This parser only supports UTF-8 encoding at the moment. This is
        # largely due to the performance impact of having to convert all of the
        # strings and regular expressions into compatible encodings. We do not
        # attempt to transcode, as the locations would all be off at that point.
        if yaml.encoding != Encoding::UTF_8
          raise ArgumentError, "Expected UTF-8 encoding, got #{yaml.encoding}"
        end

        yaml += "\n" if !yaml.empty? && !yaml.end_with?("\n")
        @scanner = StringScanner.new(yaml)
        @filename = filename
        @source = Source.new(yaml)
        @comments = {} if comments

        raise_syntax_error("Parser failed to complete") unless parse_l_yaml_stream
        raise_syntax_error("Parser finished before end of input") unless @scanner.eos?

        @comments = nil if comments
        true
      end

      private

      # Raise a syntax error with the given message.
      def raise_syntax_error(message)
        line = @source.line(@scanner.pos)
        column = @source.column(@scanner.pos)
        raise SyntaxError.new(@filename, line, column, @scanner.pos, message, nil)
      end

      # ------------------------------------------------------------------------
      # :section: Parsing helpers
      # ------------------------------------------------------------------------

      # In certain cirumstances, we need to determine the indent based on the
      # content that follows the current position. This method implements that
      # logic.
      def detect_indent(n)
        pos = @scanner.pos
        in_seq = pos > 0 && @scanner.string.byteslice(pos - 1).match?(/[\-\?\:]/)

        match = @scanner.check(%r{((?:\ *(?:\#.*)?\n)*)(\ *)}) or raise InternalException
        pre = @scanner[1]
        m = @scanner[2].length

        if in_seq && pre.empty?
          m += 1 if n == -1
        else
          m -= n
        end

        m = 0 if m < 0
        m
      end

      # This is a convenience method used to retrieve a segment of the string
      # that was just matched by the scanner. It takes a position and returns
      # the input string from that position to the current scanner position.
      def from(pos)
        @scanner.string.byteslice(pos...@scanner.pos)
      end

      # This is the only way that the scanner is advanced. It checks if the
      # given value matches the current position (either with a string or
      # regular expression). If it does, it advances the scanner and returns
      # true. If it does not, it returns false.
      def match(value)
        if @in_bare_document
          return false if @scanner.eos?
          return false if ((pos = @scanner.pos) == 0 || (@scanner.string.byteslice(pos - 1) == "\n")) && @scanner.check(/(?:---|\.\.\.)(?=\s|$)/)
        end

        @scanner.skip(value)
      end

      # This is effectively the same as match, except that it does not advance
      # the scanner if the given match is found.
      def peek
        pos_start = @scanner.pos
        result = try { yield }
        @scanner.pos = pos_start
        result
      end

      # In the grammar when a rule has rule+, it means it should match one or
      # more times. This is a convenience method that implements that logic by
      # attempting to match the given block one or more times.
      def plus
        return false unless yield
        pos_current = @scanner.pos
        pos_current = @scanner.pos while yield && (@scanner.pos != pos_current)
        true
      end

      # In the grammar when a rule has rule*, it means it should match zero or
      # more times. This is a convenience method that implements that logic by
      # attempting to match the given block zero or more times.
      def star
        pos_current = @scanner.pos
        pos_current = @scanner.pos while yield && (@scanner.pos != pos_current)
        true
      end

      # True if the scanner it at the beginning of the string, the end of the
      # string, or the previous character was a newline.
      def start_of_line?
        (pos = @scanner.pos) == 0 ||
          @scanner.eos? ||
          (@scanner.string.byteslice(pos - 1) == "\n")
      end

      # This is our main backtracking mechanism. It attempts to parse forward
      # using the given block and return true. If it fails, it backtracks to the
      # original position and returns false.
      def try
        pos_start = @scanner.pos
        yield || (@scanner.pos = pos_start; false)
      end

      # ------------------------------------------------------------------------
      # :section: Event handling
      # ------------------------------------------------------------------------

      # Flush the comments into the handler once we get to a safe point.
      def comments_flush
        return unless @comments
        @comments.each { |_, comment| @handler.comment(comment) }
        @comments.clear
      end

      # If there is a document end event, then flush it to the list of events
      # and reset back to the starting state to parse the next document.
      def document_end_event_flush
        if @document_end_event
          comments_flush
          @document_end_event.accept(@handler)
          @document_start_event = DocumentStart.new(Location.point(@source, @scanner.pos))
          @tag_directives = @document_start_event.tag_directives
          @document_end_event = nil
        end
      end

      # Push a new temporary list onto the events cache.
      def events_cache_push
        @events_cache << []
      end

      # Pop a temporary list from the events cache.
      def events_cache_pop
        @events_cache.pop or raise InternalException
      end

      # Pop a temporary list from the events cache and flush it to the next
      # level down in the cache or directly to the handler.
      def events_cache_flush
        events_cache_pop.each { |event| events_push(event) }
      end

      # Push an event into the events list. This could be pushing into the most
      # recent temporary list if there is one, or flushed directly to the
      # handler.
      def events_push(event)
        if @events_cache.empty?
          if @document_start_event
            case event
            when MappingStart, SequenceStart, Scalar
              @document_start_event.accept(@handler)
              @document_start_event = nil
              @document_end_event = DocumentEnd.new(Location.point(@source, @scanner.pos))
            end
          end

          event.accept(@handler)
        else
          @events_cache.last << event
        end
      end

      # Push an event into the events list and flush the anchor and tag
      # properties if they are set.
      def events_push_flush_properties(event)
        if @anchor
          event.anchor = @anchor
          @anchor = nil
        end

        if @tag
          event.tag = @tag
          @tag = nil
        end

        events_push(event)
      end

      # ------------------------------------------------------------------------
      # :section: Grammar rules
      # ------------------------------------------------------------------------

      # [002]
      # nb-json ::=
      #   x:9 | [x:20-x:10FFFF]
      def parse_nb_json
        match(/[\u{09}\u{20}-\u{10FFFF}]/)
      end

      # [023]
      # c-flow-indicator ::=
      #   ',' | '[' | ']' | '{' | '}'
      def parse_c_flow_indicator
        match(/[,\[\]{}]/)
      end

      # [027]
      # nb-char ::=
      #   c-printable - b-char - c-byte-order-mark
      def parse_nb_char
        pos_start = @scanner.pos

        if match(/[\u{09}\u{0A}\u{0D}\u{20}-\u{7E}\u{85}\u{A0}-\u{D7FF}\u{E000}-\u{FFFD}\u{10000}-\u{10FFFF}]/)
          pos_end = @scanner.pos
          @scanner.pos = pos_start

          if match(/[\u{0A}\u{0D}\u{FEFF}]/)
            @scanner.pos = pos_start
            false
          else
            @scanner.pos = pos_end
            true
          end
        else
          @scanner.pos = pos_start
          false
        end
      end

      # [028]
      # b-break ::=
      #   ( b-carriage-return b-line-feed )
      #   | b-carriage-return
      #   | b-line-feed
      def parse_b_break
        match(/\u{0A}|\u{0D}\u{0A}?/)
      end

      # [029]
      # b-as-line-feed ::=
      #   b-break
      alias parse_b_as_line_feed parse_b_break

      # [030]
      # b-non-content ::=
      #   b-break
      alias parse_b_non_content parse_b_break

      # [033]
      # s-white ::=
      #   s-space | s-tab
      def parse_s_white
        pos_start = @scanner.pos

        if match(/[\u{20}\u{09}]/)
          @text_prefix = from(pos_start) if @in_scalar
          true
        end
      end

      # Effectively star { parse_s_white }
      def parse_s_white_star
        match(/[\u{20}\u{09}]*/)
        true
      end

      # [034]
      # ns-char ::=
      #   nb-char - s-white
      def parse_ns_char
        pos_start = @scanner.pos

        if begin
          if parse_nb_char
            pos_end = @scanner.pos
            @scanner.pos = pos_start

            if parse_s_white
              @scanner.pos = pos_start
              false
            else
              @scanner.pos = pos_end
              true
            end
          end
        end then
          @text_prefix = from(pos_start) if @in_scalar
          true
        end
      end

      # [036]
      # ns-hex-digit ::=
      #   ns-dec-digit
      #   | [x:41-x:46] | [x:61-x:66]
      def parse_ns_hex_digit
        match(/[\u{30}-\u{39}\u{41}-\u{46}\u{61}-\u{66}]/)
      end

      # [039]
      # ns-uri-char ::=
      #   '%' ns-hex-digit ns-hex-digit | ns-word-char | '#'
      #   | ';' | '/' | '?' | ':' | '@' | '&' | '=' | '+' | '$' | ','
      #   | '_' | '.' | '!' | '~' | '*' | ''' | '(' | ')' | '[' | ']'
      def parse_ns_uri_char
        try { match("%") && parse_ns_hex_digit && parse_ns_hex_digit } ||
          match(/[\u{30}-\u{39}\u{41}-\u{5A}\u{61}-\u{7A}\-#;\/?:@&=+$,_.!~*'\(\)\[\]]/)
      end

      # [040]
      # ns-tag-char ::=
      #   ns-uri-char - '!' - c-flow-indicator
      def parse_ns_tag_char
        pos_start = @scanner.pos

        if parse_ns_uri_char
          pos_end = @scanner.pos
          @scanner.pos = pos_start

          if match("!") || parse_c_flow_indicator
            @scanner.pos = pos_start
            false
          else
            @scanner.pos = pos_end
            true
          end
        end
      end

      # [062]
      # c-ns-esc-char ::=
      #   c-escape
      #   ( ns-esc-null | ns-esc-bell | ns-esc-backspace
      #   | ns-esc-horizontal-tab | ns-esc-line-feed
      #   | ns-esc-vertical-tab | ns-esc-form-feed
      #   | ns-esc-carriage-return | ns-esc-escape | ns-esc-space
      #   | ns-esc-double-quote | ns-esc-slash | ns-esc-backslash
      #   | ns-esc-next-line | ns-esc-non-breaking-space
      #   | ns-esc-line-separator | ns-esc-paragraph-separator
      #   | ns-esc-8-bit | ns-esc-16-bit | ns-esc-32-bit )
      def parse_c_ns_esc_char
        match(/\\[0abt\u{09}nvfre\u{20}"\/\\N_LP]/) ||
          try { match("\\x") && parse_ns_hex_digit && parse_ns_hex_digit } ||
          try { match("\\u") && 4.times.all? { parse_ns_hex_digit } } ||
          try { match("\\U") && 8.times.all? { parse_ns_hex_digit } }
      end

      # [063]
      # s-indent(n) ::=
      #   s-space{n}
      def parse_s_indent(n)
        match(/\u{20}{#{n}}/)
      end

      # [031]
      # s-space ::=
      #   x:20
      #
      # [064]
      # s-indent(<n) ::=
      #   s-space{m} <where_m_<_n>
      def parse_s_indent_lt(n)
        pos_start = @scanner.pos
        match(/\u{20}*/)

        if (@scanner.pos - pos_start) < n
          true
        else
          @scanner.pos = pos_start
          false
        end
      end

      # [031]
      # s-space ::=
      #   x:20
      #
      # [065]
      # s-indent(<=n) ::=
      #   s-space{m} <where_m_<=_n>
      def parse_s_indent_le(n)
        pos_start = @scanner.pos
        match(/\u{20}*/)

        if (@scanner.pos - pos_start) <= n
          true
        else
          @scanner.pos = pos_start
          false
        end
      end

      # [066]
      # s-separate-in-line ::=
      #   s-white+ | <start_of_line>
      def parse_s_separate_in_line
        plus { parse_s_white } || start_of_line?
      end

      # [067]
      # s-line-prefix(n,c) ::=
      #   ( c = block-out => s-block-line-prefix(n) )
      #   ( c = block-in => s-block-line-prefix(n) )
      #   ( c = flow-out => s-flow-line-prefix(n) )
      #   ( c = flow-in => s-flow-line-prefix(n) )
      def parse_s_line_prefix(n, c)
        case c
        when :block_in then parse_s_block_line_prefix(n)
        when :block_out then parse_s_block_line_prefix(n)
        when :flow_in then parse_s_flow_line_prefix(n)
        when :flow_out then parse_s_flow_line_prefix(n)
        else raise InternalException, c.inspect
        end
      end

      # [068]
      # s-block-line-prefix(n) ::=
      #   s-indent(n)
      def parse_s_block_line_prefix(n)
        parse_s_indent(n)
      end

      # [069]
      # s-flow-line-prefix(n) ::=
      #   s-indent(n)
      #   s-separate-in-line?
      def parse_s_flow_line_prefix(n)
        try do
          if parse_s_indent(n)
            parse_s_separate_in_line
            true
          end
        end
      end

      # [070]
      # l-empty(n,c) ::=
      #   ( s-line-prefix(n,c) | s-indent(<n) )
      #   b-as-line-feed
      def parse_l_empty(n, c)
        if try {
          (parse_s_line_prefix(n, c) || parse_s_indent_lt(n)) &&
          parse_b_as_line_feed
        } then
          events_push("") if @in_scalar
          true
        end
      end

      # [071]
      # b-l-trimmed(n,c) ::=
      #   b-non-content l-empty(n,c)+
      def parse_b_l_trimmed(n, c)
        try { parse_b_non_content && plus { parse_l_empty(n, c) } }
      end

      # [072]
      # b-as-space ::=
      #   b-break
      alias parse_b_as_space parse_b_break

      # [073]
      # b-l-folded(n,c) ::=
      #   b-l-trimmed(n,c) | b-as-space
      def parse_b_l_folded(n, c)
        parse_b_l_trimmed(n, c) || parse_b_as_space
      end

      # [074]
      # s-flow-folded(n) ::=
      #   s-separate-in-line?
      #   b-l-folded(n,flow-in)
      #   s-flow-line-prefix(n)
      def parse_s_flow_folded(n)
        try do
          parse_s_separate_in_line
          parse_b_l_folded(n, :flow_in) && parse_s_flow_line_prefix(n)
        end
      end

      # [075]
      # c-nb-comment-text ::=
      #   '#' nb-char*
      def parse_c_nb_comment_text(inline)
        return false unless match("#")

        pos = @scanner.pos - 1
        star { parse_nb_char }

        @comments[pos] ||= Comment.new(Location.new(@source, pos, @scanner.pos), from(pos), inline) if @comments
        true
      end

      # [076]
      # b-comment ::=
      #   b-non-content | <end_of_file>
      def parse_b_comment
        parse_b_non_content || @scanner.eos?
      end

      # [077]
      # s-b-comment ::=
      #   ( s-separate-in-line
      #   c-nb-comment-text? )?
      #   b-comment
      def parse_s_b_comment
        try do
          try do
            if parse_s_separate_in_line
              parse_c_nb_comment_text(true)
              true
            end
          end

          parse_b_comment
        end
      end

      # [078]
      # l-comment ::=
      #   s-separate-in-line c-nb-comment-text?
      #   b-comment
      def parse_l_comment
        try do
          if parse_s_separate_in_line
            parse_c_nb_comment_text(false)
            parse_b_comment
          end
        end
      end

      # [079]
      # s-l-comments ::=
      #   ( s-b-comment | <start_of_line> )
      #   l-comment*
      def parse_s_l_comments
        try { (parse_s_b_comment || start_of_line?) && star { parse_l_comment } }
      end

      # [080]
      # s-separate(n,c) ::=
      #   ( c = block-out => s-separate-lines(n) )
      #   ( c = block-in => s-separate-lines(n) )
      #   ( c = flow-out => s-separate-lines(n) )
      #   ( c = flow-in => s-separate-lines(n) )
      #   ( c = block-key => s-separate-in-line )
      #   ( c = flow-key => s-separate-in-line )
      def parse_s_separate(n, c)
        case c
        when :block_in then parse_s_separate_lines(n)
        when :block_key then parse_s_separate_in_line
        when :block_out then parse_s_separate_lines(n)
        when :flow_in then parse_s_separate_lines(n)
        when :flow_key then parse_s_separate_in_line
        when :flow_out then parse_s_separate_lines(n)
        else raise InternalException, c.inspect
        end
      end

      # [081]
      # s-separate-lines(n) ::=
      #   ( s-l-comments
      #   s-flow-line-prefix(n) )
      #   | s-separate-in-line
      def parse_s_separate_lines(n)
        try { parse_s_l_comments && parse_s_flow_line_prefix(n) } ||
          parse_s_separate_in_line
      end

      # [082]
      # l-directive ::=
      #   '%'
      #   ( ns-yaml-directive
      #   | ns-tag-directive
      #   | ns-reserved-directive )
      #   s-l-comments
      def parse_l_directive
        try do
          match("%") &&
            (parse_ns_yaml_directive || parse_ns_tag_directive || parse_ns_reserved_directive) &&
            parse_s_l_comments
        end
      end

      # [083]
      # ns-reserved-directive ::=
      #   ns-directive-name
      #   ( s-separate-in-line ns-directive-parameter )*
      def parse_ns_reserved_directive
        try do
          parse_ns_directive_name &&
            star { try { parse_s_separate_in_line && parse_ns_directive_parameter } }
        end
      end

      # [084]
      # ns-directive-name ::=
      #   ns-char+
      def parse_ns_directive_name
        plus { parse_ns_char }
      end

      # [085]
      # ns-directive-parameter ::=
      #   ns-char+
      def parse_ns_directive_parameter
        plus { parse_ns_char }
      end

      # [086]
      # ns-yaml-directive ::=
      #   'Y' 'A' 'M' 'L'
      #   s-separate-in-line ns-yaml-version
      def parse_ns_yaml_directive
        try { match("YAML") && parse_s_separate_in_line && parse_ns_yaml_version }
      end

      # [035]
      # ns-dec-digit ::=
      #   [x:30-x:39]
      #
      # [087]
      # ns-yaml-version ::=
      #   ns-dec-digit+ '.' ns-dec-digit+
      def parse_ns_yaml_version
        pos_start = @scanner.pos

        if try {
          plus { match(/[\u{30}-\u{39}]/) } &&
          match(".") &&
          plus { match(/[\u{30}-\u{39}]/) }
        } then
          raise_syntax_error("Multiple %YAML directives not allowed") if @document_start_event.version
          @document_start_event.version = from(pos_start).split(".").map { |digits| digits.to_i(10) }
          true
        end
      end

      # [088]
      # ns-tag-directive ::=
      #   'T' 'A' 'G'
      #   s-separate-in-line c-tag-handle
      #   s-separate-in-line ns-tag-prefix
      def parse_ns_tag_directive
        try do
          match("TAG") &&
            parse_s_separate_in_line &&
            parse_c_tag_handle &&
            parse_s_separate_in_line &&
            parse_ns_tag_prefix
        end
      end

      # [092]
      # c-named-tag-handle ::=
      #   '!' ns-word-char+ '!'
      def parse_c_tag_handle
        pos_start = @scanner.pos

        if begin
          try do
            match("!") &&
              plus { match(/[\u{30}-\u{39}\u{41}-\u{5A}\u{61}-\u{7A}-]/) } &&
              match("!")
          end || match(/!!?/)
        end then
          @tag_handle = from(pos_start)
          true
        end
      end

      # [093]
      # ns-tag-prefix ::=
      #   c-ns-local-tag-prefix | ns-global-tag-prefix
      def parse_ns_tag_prefix
        pos_start = @scanner.pos

        if parse_c_ns_local_tag_prefix || parse_ns_global_tag_prefix
          @tag_directives[@tag_handle] = from(pos_start)
          true
        end
      end

      # [094]
      # c-ns-local-tag-prefix ::=
      #   '!' ns-uri-char*
      def parse_c_ns_local_tag_prefix
        try { match("!") && star { parse_ns_uri_char } }
      end

      # [095]
      # ns-global-tag-prefix ::=
      #   ns-tag-char ns-uri-char*
      def parse_ns_global_tag_prefix
        try { parse_ns_tag_char && star { parse_ns_uri_char } }
      end

      # [096]
      # c-ns-properties(n,c) ::=
      #   ( c-ns-tag-property
      #   ( s-separate(n,c) c-ns-anchor-property )? )
      #   | ( c-ns-anchor-property
      #   ( s-separate(n,c) c-ns-tag-property )? )
      def parse_c_ns_properties(n, c)
        try do
          if parse_c_ns_tag_property
            try { parse_s_separate(n, c) && parse_c_ns_anchor_property }
            true
          end
        end ||
        try do
          if parse_c_ns_anchor_property
            try { parse_s_separate(n, c) && parse_c_ns_tag_property }
            true
          end
        end
      end

      # [097]
      # c-ns-tag-property ::=
      #   c-verbatim-tag
      #   | c-ns-shorthand-tag
      #   | c-non-specific-tag
      #
      # [098]
      # c-verbatim-tag ::=
      #   '!' '<' ns-uri-char+ '>'
      #
      # [099]
      # c-ns-shorthand-tag ::=
      #   c-tag-handle ns-tag-char+
      #
      # [100]
      # c-non-specific-tag ::=
      #   '!'
      def parse_c_ns_tag_property
        pos_start = @scanner.pos

        if try { match("!<") && plus { parse_ns_uri_char } && match(">") }
          @tag = from(pos_start)[/\A!<(.*)>\z/, 1].gsub(/%([0-9a-fA-F]{2})/) { $1.to_i(16).chr(Encoding::UTF_8) }
          true
        elsif try { parse_c_tag_handle && plus { parse_ns_tag_char } }
          tag = from(pos_start)
          @tag =
            if (m = tag.match(/\A!!(.*)/))
              (prefix = @tag_directives["!!"]) ? (prefix + tag[2..]) : "tag:yaml.org,2002:#{m[1]}"
            elsif (m = tag.match(/\A(!.*?!)/))
              raise_syntax_error("No %TAG entry for '#{prefix}'") if !(prefix = @tag_directives[m[1]])
              prefix + tag[m[1].length..]
            elsif (prefix = @tag_directives["!"])
              prefix + tag[1..]
            else
              tag
            end

          @tag.gsub!(/%([0-9a-fA-F]{2})/) { $1.to_i(16).chr(Encoding::UTF_8) }
          true
        elsif match("!")
          @tag = @tag_directives.fetch("!", "!")
          true
        end
      end

      # [101]
      # c-ns-anchor-property ::=
      #   '&' ns-anchor-name
      def parse_c_ns_anchor_property
        pos_start = @scanner.pos

        if try { match("&") && plus { parse_ns_anchor_char } }
          @anchor = from(pos_start).byteslice(1..)
          true
        end
      end

      # [102]
      # ns-anchor-char ::=
      #   ns-char - c-flow-indicator
      def parse_ns_anchor_char
        pos_start = @scanner.pos

        if parse_ns_char
          pos_end = @scanner.pos
          @scanner.pos = pos_start

          if parse_c_flow_indicator
            @scanner.pos = pos_start
            false
          else
            @scanner.pos = pos_end
            true
          end
        end
      end

      # [104]
      # c-ns-alias-node ::=
      #   '*' ns-anchor-name
      def parse_c_ns_alias_node
        pos_start = @scanner.pos

        if try { match("*") && plus { parse_ns_anchor_char } }
          events_push_flush_properties(Alias.new(Location.new(@source, pos_start, @scanner.pos), from(pos_start).byteslice(1..)))
          true
        end
      end

      # [105]
      # e-scalar ::=
      #   <empty>
      def parse_e_scalar
        events_push_flush_properties(Scalar.new(Location.point(@source, @scanner.pos), "", Nodes::Scalar::PLAIN))
        true
      end

      # [106]
      # e-node ::=
      #   e-scalar
      alias parse_e_node parse_e_scalar

      # [107]
      # nb-double-char ::=
      #   c-ns-esc-char | ( nb-json - '\' - '"' )
      def parse_nb_double_char
        return true if parse_c_ns_esc_char
        pos_start = @scanner.pos

        if parse_nb_json
          pos_end = @scanner.pos
          @scanner.pos = pos_start

          if match(/[\\"]/)
            @scanner.pos = pos_start
            false
          else
            @scanner.pos = pos_end
            true
          end
        end
      end

      # [108]
      # ns-double-char ::=
      #   nb-double-char - s-white
      def parse_ns_double_char
        pos_start = @scanner.pos

        if parse_nb_double_char
          pos_end = @scanner.pos
          @scanner.pos = pos_start

          if parse_s_white
            @scanner.pos = pos_start
            false
          else
            @scanner.pos = pos_end
            true
          end
        end
      end

      # The following unescape sequences are supported in double quoted scalars.
      C_DOUBLE_QUOTED_UNESCAPES = {
        "\\\\" => "\\",
        "\\r\\n" => "\n",
        "\\ " => " ",
        '\\"' => '"',
        "\\/" => "/",
        "\\_" => "\u{a0}",
        "\\0" => "\x00",
        "\\a" => "\x07",
        "\\b" => "\x08",
        "\\e" => "\x1b",
        "\\f" => "\x0c",
        "\\n" => "\x0a",
        "\\r" => "\x0d",
        "\\t" => "\x09",
        "\\\t" => "\x09",
        "\\v" => "\x0b",
        "\\L" => "\u{2028}",
        "\\N" => "\u{85}",
        "\\P" => "\u{2029}"
      }.freeze

      private_constant :C_DOUBLE_QUOTED_UNESCAPES

      # [109]
      # c-double-quoted(n,c) ::=
      #   '"' nb-double-text(n,c)
      #   '"'
      def parse_c_double_quoted(n, c)
        pos_start = @scanner.pos

        if try { match("\"") && parse_nb_double_text(n, c) && match("\"") }
          end1 = "(?:\\\\\\r?\\n[ \\t]*)"
          end2 = "(?:[ \\t]*\\r?\\n[ \\t]*)"
          hex = "[0-9a-fA-F]"
          hex2 = "(?:\\\\x(#{hex}{2}))"
          hex4 = "(?:\\\\u(#{hex}{4}))"
          hex8 = "(?:\\\\U(#{hex}{8}))"

          value = from(pos_start).byteslice(1...-1)
          value.gsub!(%r{(?:\r\n|#{end1}|#{end2}+|#{hex2}|#{hex4}|#{hex8}|\\[\\ "/_0abefnrt\tvLNP])}) do |m|
            case m
            when /\A(?:#{hex2}|#{hex4}|#{hex8})\z/o
              m[2..].to_i(16).chr(Encoding::UTF_8)
            when /\A#{end1}\z/o
              ""
            when /\A#{end2}+\z/o
              m.sub(/#{end2}/, "").gsub(/#{end2}/, "\n").then { |r| r.empty? ? " " : r }
            else
              C_DOUBLE_QUOTED_UNESCAPES.fetch(m, m)
            end
          end

          events_push_flush_properties(Scalar.new(Location.new(@source, pos_start, @scanner.pos), value, Nodes::Scalar::DOUBLE_QUOTED))
          true
        end
      end

      # [110]
      # nb-double-text(n,c) ::=
      #   ( c = flow-out => nb-double-multi-line(n) )
      #   ( c = flow-in => nb-double-multi-line(n) )
      #   ( c = block-key => nb-double-one-line )
      #   ( c = flow-key => nb-double-one-line )
      def parse_nb_double_text(n, c)
        case c
        when :block_key then parse_nb_double_one_line
        when :flow_in then parse_nb_double_multi_line(n)
        when :flow_key then parse_nb_double_one_line
        when :flow_out then parse_nb_double_multi_line(n)
        else raise InternalException, c.inspect
        end
      end

      # [111]
      # nb-double-one-line ::=
      #   nb-double-char*
      def parse_nb_double_one_line
        star { parse_nb_double_char }
      end

      # [112]
      # s-double-escaped(n) ::=
      #   s-white* '\'
      #   b-non-content
      #   l-empty(n,flow-in)* s-flow-line-prefix(n)
      def parse_s_double_escaped(n)
        try do
          parse_s_white_star &&
            match("\\") &&
            parse_b_non_content &&
            star { parse_l_empty(n, :flow_in) } &&
            parse_s_flow_line_prefix(n)
        end
      end

      # [113]
      # s-double-break(n) ::=
      #   s-double-escaped(n) | s-flow-folded(n)
      def parse_s_double_break(n)
        parse_s_double_escaped(n) || parse_s_flow_folded(n)
      end

      # [114]
      # nb-ns-double-in-line ::=
      #   ( s-white* ns-double-char )*
      def parse_nb_ns_double_in_line
        star { try { parse_s_white_star && parse_ns_double_char } }
      end

      # [115]
      # s-double-next-line(n) ::=
      #   s-double-break(n)
      #   ( ns-double-char nb-ns-double-in-line
      #   ( s-double-next-line(n) | s-white* ) )?
      def parse_s_double_next_line(n)
        try do
          if parse_s_double_break(n)
            try do
              parse_ns_double_char &&
                parse_nb_ns_double_in_line &&
                (parse_s_double_next_line(n) || parse_s_white_star)
            end

            true
          end
        end
      end

      # [116]
      # nb-double-multi-line(n) ::=
      #   nb-ns-double-in-line
      #   ( s-double-next-line(n) | s-white* )
      def parse_nb_double_multi_line(n)
        try do
          parse_nb_ns_double_in_line &&
            (parse_s_double_next_line(n) || parse_s_white_star)
        end
      end

      # [117]
      # c-quoted-quote ::=
      #   ''' '''
      #
      # [118]
      # nb-single-char ::=
      #   c-quoted-quote | ( nb-json - ''' )
      def parse_nb_single_char
        return true if match("''")
        pos_start = @scanner.pos

        if parse_nb_json
          pos_end = @scanner.pos
          @scanner.pos = pos_start

          if match("'")
            @scanner.pos = pos_start
            false
          else
            @scanner.pos = pos_end
            true
          end
        end
      end

      # [119]
      # ns-single-char ::=
      #   nb-single-char - s-white
      def parse_ns_single_char
        pos_start = @scanner.pos

        if parse_nb_single_char
          pos_end = @scanner.pos
          @scanner.pos = pos_start

          if parse_s_white
            @scanner.pos = pos_start
            false
          else
            @scanner.pos = pos_end
            true
          end
        end
      end

      # [120]
      # c-single-quoted(n,c) ::=
      #   ''' nb-single-text(n,c)
      #   '''
      def parse_c_single_quoted(n, c)
        pos_start = @scanner.pos

        if try { match("'") && parse_nb_single_text(n, c) && match("'") }
          value = from(pos_start).byteslice(1...-1)
          value.gsub!(/(?:[\ \t]*\r?\n[\ \t]*)/, "\n")
          value.gsub!(/\n(\n*)/) { $1.empty? ? " " : $1 }
          value.gsub!("''", "'")
          events_push_flush_properties(Scalar.new(Location.new(@source, pos_start, @scanner.pos), value, Nodes::Scalar::SINGLE_QUOTED))
          true
        end
      end

      # [121]
      # nb-single-text(n,c) ::=
      #   ( c = flow-out => nb-single-multi-line(n) )
      #   ( c = flow-in => nb-single-multi-line(n) )
      #   ( c = block-key => nb-single-one-line )
      #   ( c = flow-key => nb-single-one-line )
      def parse_nb_single_text(n, c)
        case c
        when :block_key then parse_nb_single_one_line
        when :flow_in then parse_nb_single_multi_line(n)
        when :flow_key then parse_nb_single_one_line
        when :flow_out then parse_nb_single_multi_line(n)
        else raise InternalException, c.inspect
        end
      end

      # [122]
      # nb-single-one-line ::=
      #   nb-single-char*
      def parse_nb_single_one_line
        star { parse_nb_single_char }
      end

      # [123]
      # nb-ns-single-in-line ::=
      #   ( s-white* ns-single-char )*
      def parse_nb_ns_single_in_line
        star { try { parse_s_white_star && parse_ns_single_char } }
      end

      # [124]
      # s-single-next-line(n) ::=
      #   s-flow-folded(n)
      #   ( ns-single-char nb-ns-single-in-line
      #   ( s-single-next-line(n) | s-white* ) )?
      def parse_s_single_next_line(n)
        try do
          if parse_s_flow_folded(n)
            try do
              parse_ns_single_char &&
                parse_nb_ns_single_in_line &&
                (parse_s_single_next_line(n) || parse_s_white_star)
            end

            true
          end
        end
      end

      # [125]
      # nb-single-multi-line(n) ::=
      #   nb-ns-single-in-line
      #   ( s-single-next-line(n) | s-white* )
      def parse_nb_single_multi_line(n)
        try do
          parse_nb_ns_single_in_line &&
            (parse_s_single_next_line(n) || parse_s_white_star)
        end
      end

      # [126]
      # ns-plain-first(c) ::=
      #   ( ns-char - c-indicator )
      #   | ( ( '?' | ':' | '-' )
      #   <followed_by_an_ns-plain-safe(c)> )
      def parse_ns_plain_first(c)
        begin
          pos_start = @scanner.pos

          if parse_ns_char
            pos_end = @scanner.pos
            @scanner.pos = pos_start

            if match(/[-?:,\[\]{}#&*!|>'"%@`]/)
              @scanner.pos = pos_start
              false
            else
              @scanner.pos = pos_end
              true
            end
          end
        end || try { match(/[?:-]/) && peek { parse_ns_plain_safe(c) } }
      end

      # [127]
      # ns-plain-safe(c) ::=
      #   ( c = flow-out => ns-plain-safe-out )
      #   ( c = flow-in => ns-plain-safe-in )
      #   ( c = block-key => ns-plain-safe-out )
      #   ( c = flow-key => ns-plain-safe-in )
      def parse_ns_plain_safe(c)
        case c
        when :block_key then parse_ns_plain_safe_out
        when :flow_in then parse_ns_plain_safe_in
        when :flow_key then parse_ns_plain_safe_in
        when :flow_out then parse_ns_plain_safe_out
        else raise InternalException, c.inspect
        end
      end

      # [128]
      # ns-plain-safe-out ::=
      #   ns-char
      alias parse_ns_plain_safe_out parse_ns_char

      # [129]
      # ns-plain-safe-in ::=
      #   ns-char - c-flow-indicator
      def parse_ns_plain_safe_in
        pos_start = @scanner.pos

        if parse_ns_char
          pos_end = @scanner.pos
          @scanner.pos = pos_start

          if parse_c_flow_indicator
            @scanner.pos = pos_start
            false
          else
            @scanner.pos = pos_end
            true
          end
        end
      end

      # [130]
      # ns-plain-char(c) ::=
      #   ( ns-plain-safe(c) - ':' - '#' )
      #   | ( <an_ns-char_preceding> '#' )
      #   | ( ':' <followed_by_an_ns-plain-safe(c)> )
      def parse_ns_plain_char(c)
        try do
          pos_start = @scanner.pos

          if parse_ns_plain_safe(c)
            pos_end = @scanner.pos
            @scanner.pos = pos_start

            if match(/[:#]/)
              false
            else
              @scanner.pos = pos_end
              true
            end
          end
        end ||
        try do
          pos_start = @scanner.pos
          @scanner.pos -= 1

          was_ns_char = parse_ns_char
          @scanner.pos = pos_start

          was_ns_char && match("#")
        end ||
        try do
          match(":") && peek { parse_ns_plain_safe(c) }
        end
      end

      # [132]
      # nb-ns-plain-in-line(c) ::=
      #   ( s-white*
      #   ns-plain-char(c) )*
      def parse_nb_ns_plain_in_line(c)
        star { try { parse_s_white_star && parse_ns_plain_char(c) } }
      end

      # [133]
      # ns-plain-one-line(c) ::=
      #   ns-plain-first(c)
      #   nb-ns-plain-in-line(c)
      def parse_ns_plain_one_line(c)
        try { parse_ns_plain_first(c) && parse_nb_ns_plain_in_line(c) }
      end

      # [134]
      # s-ns-plain-next-line(n,c) ::=
      #   s-flow-folded(n)
      #   ns-plain-char(c) nb-ns-plain-in-line(c)
      def parse_s_ns_plain_next_line(n, c)
        try do
          parse_s_flow_folded(n) &&
            parse_ns_plain_char(c) &&
            parse_nb_ns_plain_in_line(c)
        end
      end

      # [135]
      # ns-plain-multi-line(n,c) ::=
      #   ns-plain-one-line(c)
      #   s-ns-plain-next-line(n,c)*
      def parse_ns_plain_multi_line(n, c)
        try do
          parse_ns_plain_one_line(c) &&
            star { parse_s_ns_plain_next_line(n, c) }
        end
      end

      # [136]
      # in-flow(c) ::=
      #   ( c = flow-out => flow-in )
      #   ( c = flow-in => flow-in )
      #   ( c = block-key => flow-key )
      #   ( c = flow-key => flow-key )
      def parse_in_flow(c)
        case c
        when :block_key then :flow_key
        when :flow_in then :flow_in
        when :flow_key then :flow_key
        when :flow_out then :flow_in
        else raise InternalException, c.inspect
        end
      end

      # [137]
      # c-flow-sequence(n,c) ::=
      #   '[' s-separate(n,c)?
      #   ns-s-flow-seq-entries(n,in-flow(c))? ']'
      def parse_c_flow_sequence(n, c)
        try do
          if match("[")
            events_push_flush_properties(SequenceStart.new(Location.new(@source, @scanner.pos - 1, @scanner.pos), Nodes::Sequence::FLOW))

            parse_s_separate(n, c)
            parse_ns_s_flow_seq_entries(n, parse_in_flow(c))

            if match("]")
              events_push_flush_properties(SequenceEnd.new(Location.new(@source, @scanner.pos - 1, @scanner.pos)))
              true
            end
          end
        end
      end

      # [138]
      # ns-s-flow-seq-entries(n,c) ::=
      #   ns-flow-seq-entry(n,c)
      #   s-separate(n,c)?
      #   ( ',' s-separate(n,c)?
      #   ns-s-flow-seq-entries(n,c)? )?
      def parse_ns_s_flow_seq_entries(n, c)
        try do
          if parse_ns_flow_seq_entry(n, c)
            parse_s_separate(n, c)

            try do
              if match(",")
                parse_s_separate(n, c)
                parse_ns_s_flow_seq_entries(n, c)
                true
              end
            end

            true
          end
        end
      end

      # [139]
      # ns-flow-seq-entry(n,c) ::=
      #   ns-flow-pair(n,c) | ns-flow-node(n,c)
      def parse_ns_flow_seq_entry(n, c)
        parse_ns_flow_pair(n, c) || parse_ns_flow_node(n, c)
      end

      # [140]
      # c-flow-mapping(n,c) ::=
      #   '{' s-separate(n,c)?
      #   ns-s-flow-map-entries(n,in-flow(c))? '}'
      def parse_c_flow_mapping(n, c)
        try do
          if match("{")
            events_push_flush_properties(MappingStart.new(Location.new(@source, @scanner.pos - 1, @scanner.pos), Nodes::Mapping::FLOW))

            parse_s_separate(n, c)
            parse_ns_s_flow_map_entries(n, parse_in_flow(c))

            if match("}")
              events_push_flush_properties(MappingEnd.new(Location.new(@source, @scanner.pos - 1, @scanner.pos)))
              true
            end
          end
        end
      end

      # [141]
      # ns-s-flow-map-entries(n,c) ::=
      #   ns-flow-map-entry(n,c)
      #   s-separate(n,c)?
      #   ( ',' s-separate(n,c)?
      #   ns-s-flow-map-entries(n,c)? )?
      def parse_ns_s_flow_map_entries(n, c)
        try do
          if parse_ns_flow_map_entry(n, c)
            parse_s_separate(n, c)

            try do
              if match(",")
                parse_s_separate(n, c)
                parse_ns_s_flow_map_entries(n, c)
                true
              end
            end

            true
          end
        end
      end

      # [142]
      # ns-flow-map-entry(n,c) ::=
      #   ( '?' s-separate(n,c)
      #   ns-flow-map-explicit-entry(n,c) )
      #   | ns-flow-map-implicit-entry(n,c)
      def parse_ns_flow_map_entry(n, c)
        try do
          match("?") &&
            peek { @scanner.eos? || parse_s_white || parse_b_break } &&
            parse_s_separate(n, c) && parse_ns_flow_map_explicit_entry(n, c)
        end || parse_ns_flow_map_implicit_entry(n, c)
      end

      # [143]
      # ns-flow-map-explicit-entry(n,c) ::=
      #   ns-flow-map-implicit-entry(n,c)
      #   | ( e-node
      #   e-node )
      def parse_ns_flow_map_explicit_entry(n, c)
        parse_ns_flow_map_implicit_entry(n, c) ||
          try { parse_e_node && parse_e_node }
      end

      # [144]
      # ns-flow-map-implicit-entry(n,c) ::=
      #   ns-flow-map-yaml-key-entry(n,c)
      #   | c-ns-flow-map-empty-key-entry(n,c)
      #   | c-ns-flow-map-json-key-entry(n,c)
      def parse_ns_flow_map_implicit_entry(n, c)
        parse_ns_flow_map_yaml_key_entry(n, c) ||
          parse_c_ns_flow_map_empty_key_entry(n, c) ||
          parse_c_ns_flow_map_json_key_entry(n, c)
      end

      # [145]
      # ns-flow-map-yaml-key-entry(n,c) ::=
      #   ns-flow-yaml-node(n,c)
      #   ( ( s-separate(n,c)?
      #   c-ns-flow-map-separate-value(n,c) )
      #   | e-node )
      def parse_ns_flow_map_yaml_key_entry(n, c)
        try do
          parse_ns_flow_yaml_node(n, c) && (
            try do
              parse_s_separate(n, c)
              parse_c_ns_flow_map_separate_value(n, c)
            end || parse_e_node
          )
        end
      end

      # [146]
      # c-ns-flow-map-empty-key-entry(n,c) ::=
      #   e-node
      #   c-ns-flow-map-separate-value(n,c)
      def parse_c_ns_flow_map_empty_key_entry(n, c)
        events_cache_push

        if try { parse_e_node && parse_c_ns_flow_map_separate_value(n, c) }
          events_cache_flush
          true
        else
          events_cache_pop
          false
        end
      end

      # [147]
      # c-ns-flow-map-separate-value(n,c) ::=
      #   ':' <not_followed_by_an_ns-plain-safe(c)>
      #   ( ( s-separate(n,c) ns-flow-node(n,c) )
      #   | e-node )
      def parse_c_ns_flow_map_separate_value(n, c)
        try do
          match(":") &&
            !peek { parse_ns_plain_safe(c) } &&
            (try { parse_s_separate(n, c) && parse_ns_flow_node(n, c) } || parse_e_node)
        end
      end

      # [148]
      # c-ns-flow-map-json-key-entry(n,c) ::=
      #   c-flow-json-node(n,c)
      #   ( ( s-separate(n,c)?
      #   c-ns-flow-map-adjacent-value(n,c) )
      #   | e-node )
      def parse_c_ns_flow_map_json_key_entry(n, c)
        try do
          parse_c_flow_json_node(n, c) && (
            try do
              parse_s_separate(n, c)
              parse_c_ns_flow_map_adjacent_value(n, c)
            end || parse_e_node
          )
        end
      end

      # [149]
      # c-ns-flow-map-adjacent-value(n,c) ::=
      #   ':' ( (
      #   s-separate(n,c)?
      #   ns-flow-node(n,c) )
      #   | e-node )
      def parse_c_ns_flow_map_adjacent_value(n, c)
        try do
          match(":") && (
            try do
              parse_s_separate(n, c)
              parse_ns_flow_node(n, c)
            end || parse_e_node
          )
        end
      end

      # [150]
      # ns-flow-pair(n,c) ::=
      #   ( '?' s-separate(n,c)
      #   ns-flow-map-explicit-entry(n,c) )
      #   | ns-flow-pair-entry(n,c)
      def parse_ns_flow_pair(n, c)
        events_cache_push
        events_push_flush_properties(MappingStart.new(Location.point(@source, @scanner.pos), Nodes::Mapping::FLOW))

        if begin
          try do
            match("?") &&
              peek { @scanner.eos? || parse_s_white || parse_b_break } &&
              parse_s_separate(n, c) &&
              parse_ns_flow_map_explicit_entry(n, c)
          end || parse_ns_flow_pair_entry(n, c)
        end then
          events_cache_flush
          events_push_flush_properties(MappingEnd.new(Location.point(@source, @scanner.pos)))
          true
        else
          events_cache_pop
          false
        end
      end

      # [151]
      # ns-flow-pair-entry(n,c) ::=
      #   ns-flow-pair-yaml-key-entry(n,c)
      #   | c-ns-flow-map-empty-key-entry(n,c)
      #   | c-ns-flow-pair-json-key-entry(n,c)
      def parse_ns_flow_pair_entry(n, c)
        parse_ns_flow_pair_yaml_key_entry(n, c) ||
          parse_c_ns_flow_map_empty_key_entry(n, c) ||
          parse_c_ns_flow_pair_json_key_entry(n, c)
      end

      # [152]
      # ns-flow-pair-yaml-key-entry(n,c) ::=
      #   ns-s-implicit-yaml-key(flow-key)
      #   c-ns-flow-map-separate-value(n,c)
      def parse_ns_flow_pair_yaml_key_entry(n, c)
        try do
          parse_ns_s_implicit_yaml_key(:flow_key) &&
            parse_c_ns_flow_map_separate_value(n, c)
        end
      end

      # [153]
      # c-ns-flow-pair-json-key-entry(n,c) ::=
      #   c-s-implicit-json-key(flow-key)
      #   c-ns-flow-map-adjacent-value(n,c)
      def parse_c_ns_flow_pair_json_key_entry(n, c)
        try do
          parse_c_s_implicit_json_key(:flow_key) &&
            parse_c_ns_flow_map_adjacent_value(n, c)
        end
      end

      # [154]
      # ns-s-implicit-yaml-key(c) ::=
      #   ns-flow-yaml-node(n/a,c)
      #   s-separate-in-line?
      #   <at_most_1024_characters_altogether>
      def parse_ns_s_implicit_yaml_key(c)
        pos_start = @scanner.pos
        try do
          if parse_ns_flow_yaml_node(nil, c)
            parse_s_separate_in_line
            (@scanner.pos - pos_start) <= 1024
          end
        end
      end

      # [155]
      # c-s-implicit-json-key(c) ::=
      #   c-flow-json-node(n/a,c)
      #   s-separate-in-line?
      #   <at_most_1024_characters_altogether>
      def parse_c_s_implicit_json_key(c)
        pos_start = @scanner.pos
        try do
          if parse_c_flow_json_node(nil, c)
            parse_s_separate_in_line
            (@scanner.pos - pos_start) <= 1024
          end
        end
      end

      # [131]
      # ns-plain(n,c) ::=
      #   ( c = flow-out => ns-plain-multi-line(n,c) )
      #   ( c = flow-in => ns-plain-multi-line(n,c) )
      #   ( c = block-key => ns-plain-one-line(c) )
      #   ( c = flow-key => ns-plain-one-line(c) )
      #
      # [156]
      # ns-flow-yaml-content(n,c) ::=
      #   ns-plain(n,c)
      def parse_ns_flow_yaml_content(n, c)
        pos_start = @scanner.pos
        result =
          case c
          when :block_key then parse_ns_plain_one_line(c)
          when :flow_in then parse_ns_plain_multi_line(n, c)
          when :flow_key then parse_ns_plain_one_line(c)
          when :flow_out then parse_ns_plain_multi_line(n, c)
          else raise InternalException, c.inspect
          end

        if result
          value = from(pos_start)
          value.gsub!(/(?:[\ \t]*\r?\n[\ \t]*)/, "\n")
          value.gsub!(/\n(\n*)/) { $1.empty? ? " " : $1 }
          events_push_flush_properties(Scalar.new(Location.new(@source, pos_start, @scanner.pos), value, Nodes::Scalar::PLAIN))
        end

        result
      end

      # [157]
      # c-flow-json-content(n,c) ::=
      #   c-flow-sequence(n,c) | c-flow-mapping(n,c)
      #   | c-single-quoted(n,c) | c-double-quoted(n,c)
      def parse_c_flow_json_content(n, c)
        parse_c_flow_sequence(n, c) ||
          parse_c_flow_mapping(n, c) ||
          parse_c_single_quoted(n, c) ||
          parse_c_double_quoted(n, c)
      end

      # [158]
      # ns-flow-content(n,c) ::=
      #   ns-flow-yaml-content(n,c) | c-flow-json-content(n,c)
      def parse_ns_flow_content(n, c)
        parse_ns_flow_yaml_content(n, c) ||
          parse_c_flow_json_content(n, c)
      end

      # [159]
      # ns-flow-yaml-node(n,c) ::=
      #   c-ns-alias-node
      #   | ns-flow-yaml-content(n,c)
      #   | ( c-ns-properties(n,c)
      #   ( ( s-separate(n,c)
      #   ns-flow-yaml-content(n,c) )
      #   | e-scalar ) )
      def parse_ns_flow_yaml_node(n, c)
        parse_c_ns_alias_node ||
          parse_ns_flow_yaml_content(n, c) ||
          try do
            parse_c_ns_properties(n, c) &&
              (try { parse_s_separate(n, c) && parse_ns_flow_content(n, c) } || parse_e_scalar)
          end
      end

      # [160]
      # c-flow-json-node(n,c) ::=
      #   ( c-ns-properties(n,c)
      #   s-separate(n,c) )?
      #   c-flow-json-content(n,c)
      def parse_c_flow_json_node(n, c)
        try do
          try { parse_c_ns_properties(n, c) && parse_s_separate(n, c) }
          parse_c_flow_json_content(n, c)
        end
      end

      # [161]
      # ns-flow-node(n,c) ::=
      #   c-ns-alias-node
      #   | ns-flow-content(n,c)
      #   | ( c-ns-properties(n,c)
      #   ( ( s-separate(n,c)
      #   ns-flow-content(n,c) )
      #   | e-scalar ) )
      def parse_ns_flow_node(n, c)
        parse_c_ns_alias_node ||
          parse_ns_flow_content(n, c) ||
          try do
            parse_c_ns_properties(n, c) &&
              (try { parse_s_separate(n, c) && parse_ns_flow_content(n, c) } || parse_e_scalar)
          end
      end

      # [162]
      # c-b-block-header(m,t) ::=
      #   ( ( c-indentation-indicator(m)
      #   c-chomping-indicator(t) )
      #   | ( c-chomping-indicator(t)
      #   c-indentation-indicator(m) ) )
      #   s-b-comment
      def parse_c_b_block_header(n)
        m = nil
        t = nil

        result =
          try do
            (
              try do
                (m = parse_c_indentation_indicator(n)) &&
                  (t = parse_c_chomping_indicator) &&
                  peek { @scanner.eos? || parse_s_white || parse_b_break }
              end ||
              try do
                (t = parse_c_chomping_indicator) &&
                  (m = parse_c_indentation_indicator(n)) &&
                  peek { @scanner.eos? || parse_s_white || parse_b_break }
              end
            ) && parse_s_b_comment
          end

        result ? [m, t] : false
      end

      # [163]
      # c-indentation-indicator(m) ::=
      #   ( ns-dec-digit => m = ns-dec-digit - x:30 )
      #   ( <empty> => m = auto-detect() )
      def parse_c_indentation_indicator(n)
        pos_start = @scanner.pos

        if match(/[\u{31}-\u{39}]/)
          Integer(from(pos_start))
        else
          @scanner.check(/.*\n((?:\ *\n)*)(\ *)(.?)/)

          pre = @scanner[1]
          if !@scanner[3].empty?
            m = @scanner[2].length - n
          else
            m = 0
            while pre.match?(/\ {#{m}}/)
              m += 1
            end
            m = m - n - 1
          end

          if m > 0 && pre.match?(/^.{#{m + n}}\ /)
            raise_syntax_error("Invalid indentation indicator")
          end

          m == 0 ? 1 : m
        end
      end

      # [164]
      # c-chomping-indicator(t) ::=
      #   ( '-' => t = strip )
      #   ( '+' => t = keep )
      #   ( <empty> => t = clip )
      def parse_c_chomping_indicator
        if match("-") then :strip
        elsif match("+") then :keep
        else :clip
        end
      end

      # [165]
      # b-chomped-last(t) ::=
      #   ( t = strip => b-non-content | <end_of_file> )
      #   ( t = clip => b-as-line-feed | <end_of_file> )
      #   ( t = keep => b-as-line-feed | <end_of_file> )
      def parse_b_chomped_last(t)
        case t
        when :clip then parse_b_as_line_feed || @scanner.eos?
        when :keep then parse_b_as_line_feed || @scanner.eos?
        when :strip then parse_b_non_content || @scanner.eos?
        else raise InternalException, t.inspect
        end
      end

      # [166]
      # l-chomped-empty(n,t) ::=
      #   ( t = strip => l-strip-empty(n) )
      #   ( t = clip => l-strip-empty(n) )
      #   ( t = keep => l-keep-empty(n) )
      #
      # [167]
      # l-strip-empty(n) ::=
      #   ( s-indent(<=n) b-non-content )*
      #   l-trail-comments(n)?
      #
      # [168]
      # l-keep-empty(n) ::=
      #   l-empty(n,block-in)*
      #   l-trail-comments(n)?
      def parse_l_chomped_empty(n, t)
        case t
        when :clip, :strip
          try do
            if star { try { parse_s_indent_le(n) && parse_b_non_content } }
              parse_l_trail_comments(n)
              true
            end
          end
        when :keep
          try do
            if star { parse_l_empty(n, :block_in) }
              parse_l_trail_comments(n)
              true
            end
          end
        else
          raise InternalException, t.inspect
        end
      end

      # [169]
      # l-trail-comments(n) ::=
      #   s-indent(<n)
      #   c-nb-comment-text b-comment
      #   l-comment*
      def parse_l_trail_comments(n)
        try do
          parse_s_indent_lt(n) &&
            parse_c_nb_comment_text(false) &&
            parse_b_comment &&
            star { parse_l_comment }
        end
      end

      # [170]
      # c-l+literal(n) ::=
      #   '|' c-b-block-header(m,t)
      #   l-literal-content(n+m,t)
      def parse_c_l_literal(n)
        @in_scalar = true
        events_cache_push

        m = nil
        t = nil
        pos_start = @scanner.pos

        if try {
          match("|") &&
          (m, t = parse_c_b_block_header(n)) &&
          parse_l_literal_content(n + m, t)
        } then
          @in_scalar = false
          lines = events_cache_pop
          lines.pop if lines.length > 0 && lines.last.empty?
          value = lines.map { |line| "#{line}\n" }.join

          case t
          when :clip
            value.sub!(/\n+\z/, "\n")
          when :strip
            value.sub!(/\n+\z/, "")
          when :keep
            value.sub!(/\n(\n+)\z/) { $1 } if !value.match?(/\S/)
          else
            raise InternalException, t.inspect
          end

          events_push_flush_properties(Scalar.new(Location.new(@source, pos_start, @scanner.pos), value, Nodes::Scalar::LITERAL))
          true
        else
          @in_scalar = false
          events_cache_pop
          false
        end
      end

      # [171]
      # l-nb-literal-text(n) ::=
      #   l-empty(n,block-in)*
      #   s-indent(n) nb-char+
      def parse_l_nb_literal_text(n)
        try do
          if star { parse_l_empty(n, :block_in) } && parse_s_indent(n)
            pos_start = @scanner.pos

            if plus { parse_nb_char }
              events_push(from(pos_start))
              true
            end
          end
        end
      end

      # [172]
      # b-nb-literal-next(n) ::=
      #   b-as-line-feed
      #   l-nb-literal-text(n)
      def parse_b_nb_literal_next(n)
        try { parse_b_as_line_feed && parse_l_nb_literal_text(n) }
      end

      # [173]
      # l-literal-content(n,t) ::=
      #   ( l-nb-literal-text(n)
      #   b-nb-literal-next(n)*
      #   b-chomped-last(t) )?
      #   l-chomped-empty(n,t)
      def parse_l_literal_content(n, t)
        try do
          try do
            parse_l_nb_literal_text(n) &&
              star { parse_b_nb_literal_next(n) } &&
              parse_b_chomped_last(t)
          end

          parse_l_chomped_empty(n, t)
        end
      end

      # [174]
      # c-l+folded(n) ::=
      #   '>' c-b-block-header(m,t)
      #   l-folded-content(n+m,t)
      def parse_c_l_folded(n)
        @in_scalar = true
        @text_prefix.clear
        events_cache_push

        m = nil
        t = nil
        pos_start = @scanner.pos

        if try {
          match(">") &&
          (m, t = parse_c_b_block_header(n)) &&
          parse_l_folded_content(n + m, t)
        } then
          @in_scalar = false

          value = events_cache_pop.join("\n")
          value.gsub!(/^(\S.*)\n(?=\S)/) { "#{$1} " }
          value.gsub!(/^(\S.*)\n(\n+)/) { "#{$1}#{$2}" }
          value.gsub!(/^([\ \t]+\S.*)\n(\n+)(?=\S)/) { "#{$1}#{$2}" }
          value << "\n"

          case t
          when :clip
            value.sub!(/\n+\z/, "\n")
            value.clear if value == "\n"
          when :strip
            value.sub!(/\n+\z/, "")
          when :keep
            # nothing
          else
            raise InternalException, t.inspect
          end

          events_push_flush_properties(Scalar.new(Location.new(@source, pos_start, @scanner.pos), value, Nodes::Scalar::FOLDED))
          true
        else
          @in_scalar = false
          events_cache_pop
          false
        end
      end

      # [175]
      # s-nb-folded-text(n) ::=
      #   s-indent(n) ns-char
      #   nb-char*
      def parse_s_nb_folded_text(n)
        try do
          if parse_s_indent(n) && parse_ns_char
            pos_start = @scanner.pos

            if star { parse_nb_char }
              events_push("#{@text_prefix}#{from(pos_start)}")
              true
            end
          end
        end
      end

      # [176]
      # l-nb-folded-lines(n) ::=
      #   s-nb-folded-text(n)
      #   ( b-l-folded(n,block-in) s-nb-folded-text(n) )*
      def parse_l_nb_folded_lines(n)
        try do
          parse_s_nb_folded_text(n) &&
            star { try { parse_b_l_folded(n, :block_in) && parse_s_nb_folded_text(n) } }
        end
      end

      # [177]
      # s-nb-spaced-text(n) ::=
      #   s-indent(n) s-white
      #   nb-char*
      def parse_s_nb_spaced_text(n)
        try do
          if parse_s_indent(n) && parse_s_white
            pos_start = @scanner.pos
            star { parse_nb_char }
            events_push("#{@text_prefix}#{from(pos_start)}")
            true
          end
        end
      end

      # [178]
      # b-l-spaced(n) ::=
      #   b-as-line-feed
      #   l-empty(n,block-in)*
      def parse_b_l_spaced(n)
        try { parse_b_as_line_feed && star { parse_l_empty(n, :block_in) } }
      end

      # [179]
      # l-nb-spaced-lines(n) ::=
      #   s-nb-spaced-text(n)
      #   ( b-l-spaced(n) s-nb-spaced-text(n) )*
      def parse_l_nb_spaced_lines(n)
        try do
          parse_s_nb_spaced_text(n) &&
            star { try { parse_b_l_spaced(n) && parse_s_nb_spaced_text(n) } }
        end
      end

      # [180]
      # l-nb-same-lines(n) ::=
      #   l-empty(n,block-in)*
      #   ( l-nb-folded-lines(n) | l-nb-spaced-lines(n) )
      def parse_l_nb_same_lines(n)
        try do
          star { parse_l_empty(n, :block_in) }
          parse_l_nb_folded_lines(n) || parse_l_nb_spaced_lines(n)
        end
      end

      # [181]
      # l-nb-diff-lines(n) ::=
      #   l-nb-same-lines(n)
      #   ( b-as-line-feed l-nb-same-lines(n) )*
      def parse_l_nb_diff_lines(n)
        try do
          parse_l_nb_same_lines(n) &&
            star { try { parse_b_as_line_feed && parse_l_nb_same_lines(n) } }
        end
      end

      # [182]
      # l-folded-content(n,t) ::=
      #   ( l-nb-diff-lines(n)
      #   b-chomped-last(t) )?
      #   l-chomped-empty(n,t)
      def parse_l_folded_content(n, t)
        try do
          try { parse_l_nb_diff_lines(n) && parse_b_chomped_last(t) }
          parse_l_chomped_empty(n, t)
        end
      end

      # [183]
      # l+block-sequence(n) ::=
      #   ( s-indent(n+m)
      #   c-l-block-seq-entry(n+m) )+
      #   <for_some_fixed_auto-detected_m_>_0>
      def parse_l_block_sequence(n)
        return false if (m = detect_indent(n)) == 0

        events_cache_push
        events_push_flush_properties(SequenceStart.new(Location.point(@source, @scanner.pos), Nodes::Sequence::BLOCK))

        if try { plus { try { parse_s_indent(n + m) && parse_c_l_block_seq_entry(n + m) } } }
          events_cache_flush
          events_push_flush_properties(SequenceEnd.new(Location.point(@source, @scanner.pos)))
          true
        else
          event = events_cache_pop[0]
          @anchor = event.anchor
          @tag = event.tag
          false
        end
      end

      # [004]
      # c-sequence-entry ::=
      #   '-'
      #
      # [184]
      # c-l-block-seq-entry(n) ::=
      #   '-' <not_followed_by_an_ns-char>
      #   s-l+block-indented(n,block-in)
      def parse_c_l_block_seq_entry(n)
        try do
          match("-") &&
            !peek { parse_ns_char } &&
            parse_s_l_block_indented(n, :block_in)
        end
      end

      # [185]
      # s-l+block-indented(n,c) ::=
      #   ( s-indent(m)
      #   ( ns-l-compact-sequence(n+1+m)
      #   | ns-l-compact-mapping(n+1+m) ) )
      #   | s-l+block-node(n,c)
      #   | ( e-node s-l-comments )
      def parse_s_l_block_indented(n, c)
        m = detect_indent(n)

        try do
          parse_s_indent(m) &&
            (parse_ns_l_compact_sequence(n + 1 + m) || parse_ns_l_compact_mapping(n + 1 + m))
        end || parse_s_l_block_node(n, c) || try { parse_e_node && parse_s_l_comments }
      end

      # [186]
      # ns-l-compact-sequence(n) ::=
      #   c-l-block-seq-entry(n)
      #   ( s-indent(n) c-l-block-seq-entry(n) )*
      def parse_ns_l_compact_sequence(n)
        events_cache_push
        events_push_flush_properties(SequenceStart.new(Location.point(@source, @scanner.pos), Nodes::Sequence::BLOCK))

        if try {
          parse_c_l_block_seq_entry(n) &&
          star { try { parse_s_indent(n) && parse_c_l_block_seq_entry(n) } }
        } then
          events_cache_flush
          events_push_flush_properties(SequenceEnd.new(Location.point(@source, @scanner.pos)))
          true
        else
          events_cache_pop
          false
        end
      end

      # [187]
      # l+block-mapping(n) ::=
      #   ( s-indent(n+m)
      #   ns-l-block-map-entry(n+m) )+
      #   <for_some_fixed_auto-detected_m_>_0>
      def parse_l_block_mapping(n)
        return false if (m = detect_indent(n)) == 0

        events_cache_push
        events_push_flush_properties(MappingStart.new(Location.point(@source, @scanner.pos), Nodes::Mapping::BLOCK))

        if try { plus { try { parse_s_indent(n + m) && parse_ns_l_block_map_entry(n + m) } } }
          events_cache_flush
          events_push_flush_properties(MappingEnd.new(Location.point(@source, @scanner.pos))) # TODO
          true
        else
          events_cache_pop
          false
        end
      end

      # [188]
      # ns-l-block-map-entry(n) ::=
      #   c-l-block-map-explicit-entry(n)
      #   | ns-l-block-map-implicit-entry(n)
      def parse_ns_l_block_map_entry(n)
        parse_c_l_block_map_explicit_entry(n) ||
          parse_ns_l_block_map_implicit_entry(n)
      end

      # [189]
      # c-l-block-map-explicit-entry(n) ::=
      #   c-l-block-map-explicit-key(n)
      #   ( l-block-map-explicit-value(n)
      #   | e-node )
      def parse_c_l_block_map_explicit_entry(n)
        events_cache_push

        if try {
          parse_c_l_block_map_explicit_key(n) &&
          (parse_l_block_map_explicit_value(n) || parse_e_node)
        } then
          events_cache_flush
          true
        else
          events_cache_pop
          false
        end
      end

      # [190]
      # c-l-block-map-explicit-key(n) ::=
      #   '?'
      #   s-l+block-indented(n,block-out)
      def parse_c_l_block_map_explicit_key(n)
        try do
          match("?") &&
            peek { @scanner.eos? || parse_s_white || parse_b_break } &&
            parse_s_l_block_indented(n, :block_out)
        end
      end

      # [191]
      # l-block-map-explicit-value(n) ::=
      #   s-indent(n)
      #   ':' s-l+block-indented(n,block-out)
      def parse_l_block_map_explicit_value(n)
        try do
          parse_s_indent(n) &&
            match(":") &&
            parse_s_l_block_indented(n, :block_out)
        end
      end

      # [192]
      # ns-l-block-map-implicit-entry(n) ::=
      #   (
      #   ns-s-block-map-implicit-key
      #   | e-node )
      #   c-l-block-map-implicit-value(n)
      def parse_ns_l_block_map_implicit_entry(n)
        events_cache_push

        if try {
          (parse_ns_s_block_map_implicit_key || parse_e_node) &&
          parse_c_l_block_map_implicit_value(n)
        } then
          events_cache_flush
          true
        else
          events_cache_pop
          false
        end
      end

      # [193]
      # ns-s-block-map-implicit-key ::=
      #   c-s-implicit-json-key(block-key)
      #   | ns-s-implicit-yaml-key(block-key)
      def parse_ns_s_block_map_implicit_key
        parse_c_s_implicit_json_key(:block_key) ||
          parse_ns_s_implicit_yaml_key(:block_key)
      end

      # [194]
      # c-l-block-map-implicit-value(n) ::=
      #   ':' (
      #   s-l+block-node(n,block-out)
      #   | ( e-node s-l-comments ) )
      def parse_c_l_block_map_implicit_value(n)
        try do
          match(":") &&
            (parse_s_l_block_node(n, :block_out) || try { parse_e_node && parse_s_l_comments })
        end
      end

      # [195]
      # ns-l-compact-mapping(n) ::=
      #   ns-l-block-map-entry(n)
      #   ( s-indent(n) ns-l-block-map-entry(n) )*
      def parse_ns_l_compact_mapping(n)
        events_cache_push
        events_push_flush_properties(MappingStart.new(Location.point(@source, @scanner.pos), Nodes::Mapping::BLOCK))

        if try {
          parse_ns_l_block_map_entry(n) &&
          star { try { parse_s_indent(n) && parse_ns_l_block_map_entry(n) } }
        } then
          events_cache_flush
          events_push_flush_properties(MappingEnd.new(Location.point(@source, @scanner.pos))) # TODO
          true
        else
          events_cache_pop
          false
        end
      end

      # [196]
      # s-l+block-node(n,c) ::=
      #   s-l+block-in-block(n,c) | s-l+flow-in-block(n)
      def parse_s_l_block_node(n, c)
        parse_s_l_block_in_block(n, c) || parse_s_l_flow_in_block(n)
      end

      # [197]
      # s-l+flow-in-block(n) ::=
      #   s-separate(n+1,flow-out)
      #   ns-flow-node(n+1,flow-out) s-l-comments
      def parse_s_l_flow_in_block(n)
        try do
          parse_s_separate(n + 1, :flow_out) &&
            parse_ns_flow_node(n + 1, :flow_out) &&
            parse_s_l_comments
        end
      end

      # [198]
      # s-l+block-in-block(n,c) ::=
      #   s-l+block-scalar(n,c) | s-l+block-collection(n,c)
      def parse_s_l_block_in_block(n, c)
        parse_s_l_block_scalar(n, c) || parse_s_l_block_collection(n, c)
      end

      # [199]
      # s-l+block-scalar(n,c) ::=
      #   s-separate(n+1,c)
      #   ( c-ns-properties(n+1,c) s-separate(n+1,c) )?
      #   ( c-l+literal(n) | c-l+folded(n) )
      def parse_s_l_block_scalar(n, c)
        try do
          if parse_s_separate(n + 1, c)
            try { parse_c_ns_properties(n + 1, c) && parse_s_separate(n + 1, c) }
            parse_c_l_literal(n) || parse_c_l_folded(n)
          end
        end
      end

      # [200]
      # s-l+block-collection(n,c) ::=
      #   ( s-separate(n+1,c)
      #   c-ns-properties(n+1,c) )?
      #   s-l-comments
      #   ( l+block-sequence(seq-spaces(n,c))
      #   | l+block-mapping(n) )
      def parse_s_l_block_collection(n, c)
        try do
          try do
            next false if !parse_s_separate(n + 1, c)

            next true if try { parse_c_ns_properties(n + 1, c) && parse_s_l_comments }
            @tag = nil
            @anchor = nil

            next true if try { parse_c_ns_tag_property && parse_s_l_comments }
            @tag = nil

            next true if try { parse_c_ns_anchor_property && parse_s_l_comments }
            @anchor = nil

            false
          end

          parse_s_l_comments && (parse_l_block_sequence(parse_seq_spaces(n, c)) || parse_l_block_mapping(n))
        end
      end

      # [201]
      # seq-spaces(n,c) ::=
      #   ( c = block-out => n-1 )
      #   ( c = block-in => n )
      def parse_seq_spaces(n, c)
        case c
        when :block_in then n
        when :block_out then n - 1
        else raise InternalException, c.inspect
        end
      end

      # [003]
      # c-byte-order-mark ::=
      #   x:FEFF
      #
      # [202]
      # l-document-prefix ::=
      #   c-byte-order-mark? l-comment*
      def parse_l_document_prefix
        try do
          @scanner.skip("\u{FEFF}")
          star { parse_l_comment }
        end
      end

      # [203]
      # c-directives-end ::=
      #   '-' '-' '-'
      def parse_c_directives_end
        if try { match("---") && peek { @scanner.eos? || parse_s_white || parse_b_break } }
          document_end_event_flush
          @document_start_event.implicit = false
          true
        end
      end

      # [204]
      # c-document-end ::=
      #   '.' '.' '.'
      def parse_c_document_end
        if match("...")
          @document_end_event.implicit = false if @document_end_event
          document_end_event_flush
          true
        end
      end

      # [205]
      # l-document-suffix ::=
      #   c-document-end s-l-comments
      def parse_l_document_suffix
        try { parse_c_document_end && parse_s_l_comments }
      end

      # [207]
      # l-bare-document ::=
      #   s-l+block-node(-1,block-in)
      #   <excluding_c-forbidden_content>
      def parse_l_bare_document
        previous = @in_bare_document
        @in_bare_document = true

        result =
          try do
            !try { start_of_line? && (parse_c_directives_end || parse_c_document_end) && (match(/[\u{0A}\u{0D}]/) || parse_s_white || @scanner.eos?) } &&
              parse_s_l_block_node(-1, :block_in)
          end

        @in_bare_document = previous
        result
      end

      # [208]
      # l-explicit-document ::=
      #   c-directives-end
      #   ( l-bare-document
      #   | ( e-node s-l-comments ) )
      def parse_l_explicit_document
        try do
          parse_c_directives_end &&
            (parse_l_bare_document || try { parse_e_node && parse_s_l_comments })
        end
      end

      # [209]
      # l-directive-document ::=
      #   l-directive+
      #   l-explicit-document
      #
      # [210]
      # l-any-document ::=
      #   l-directive-document
      #   | l-explicit-document
      #   | l-bare-document
      def parse_l_any_document
        try { plus { parse_l_directive } && parse_l_explicit_document } ||
          parse_l_explicit_document ||
          parse_l_bare_document
      end

      # [211]
      # l-yaml-stream ::=
      #   l-document-prefix* l-any-document?
      #   ( ( l-document-suffix+ l-document-prefix*
      #   l-any-document? )
      #   | ( l-document-prefix* l-explicit-document? ) )*
      def parse_l_yaml_stream
        events_push_flush_properties(StreamStart.new(Location.point(@source, @scanner.pos)))

        @document_start_event = DocumentStart.new(Location.point(@source, @scanner.pos))
        @tag_directives = @document_start_event.tag_directives
        @document_end_event = nil

        if try {
          if parse_l_document_prefix
            parse_l_any_document
            star do
              try do
                if parse_l_document_suffix
                  star { parse_l_document_prefix }
                  parse_l_any_document
                  true
                end
              end ||
              try do
                if parse_l_document_prefix
                  parse_l_explicit_document
                  true
                end
              end
            end
          end
        } then
          document_end_event_flush
          events_push_flush_properties(StreamEnd.new(Location.point(@source, @scanner.pos)))
          true
        end
      end

      # ------------------------------------------------------------------------
      # :section: Debugging
      # ------------------------------------------------------------------------

      # If the DEBUG environment variable is set, we'll decorate all of the
      # parse methods and print them out as they are encountered.
      if !ENV.fetch("DEBUG", "").empty?
        class Debug < Module
          def initialize(methods)
            methods.each do |method|
              prefix = method.name.delete_prefix("parse_")

              define_method(method) do |*args|
                norm = args.map { |arg| arg.nil? ? "nil" : arg }.join(",")
                $stderr.puts(">>> #{prefix}(#{norm})")
                super(*args)
              end
            end
          end
        end

        prepend Debug.new(private_instance_methods.grep(/\Aparse_/))
      end
    end

    # The emitter is responsible for taking Ruby objects and converting them
    # into YAML documents.
    class Emitter
      # The base class for all emitter nodes. We need to build a tree of nodes
      # here in order to support dumping repeated objects as anchors and
      # aliases, since we may find that we need to add an anchor after the
      # object has already been flushed.
      class Node
        attr_reader :value, :comments

        def initialize(value, comments)
          @value = value
          @comments = comments
          @anchor = nil
        end

        def accept(visitor)
          raise
        end
      end

      # Represents an alias to another node in the tree.
      class AliasNode < Node
        def accept(visitor)
          visitor.visit_alias(self)
        end
      end

      # Represents an array of nodes.
      class ArrayNode < Node
        attr_accessor :anchor

        def accept(visitor)
          visitor.visit_array(self)
        end
      end

      # Represents a hash of nodes.
      class HashNode < Node
        attr_accessor :anchor

        def accept(visitor)
          visitor.visit_hash(self)
        end
      end

      # Represents the nil value.
      class NilNode < Node
      end

      # Represents a generic object that is not matched by any of the other node
      # types.
      class ObjectNode < Node
        def accept(visitor)
          visitor.visit_object(self)
        end
      end

      # Represents a Psych::Omap object.
      class OmapNode < Node
        attr_accessor :anchor

        def accept(visitor)
          visitor.visit_omap(self)
        end
      end

      # Represents a Psych::Set object.
      class SetNode < Node
        attr_accessor :anchor

        def accept(visitor)
          visitor.visit_set(self)
        end
      end

      # Represents a string object.
      class StringNode < Node
        def accept(visitor)
          visitor.visit_string(self)
        end
      end

      # The visitor is responsible for walking the tree and generating the YAML
      # output.
      class Visitor
        def initialize(q)
          @q = q
        end

        # Visit an AliasNode.
        def visit_alias(node)
          with_comments(node) { |value| @q.text("*#{value}") }
        end

        # Visit an ArrayNode.
        def visit_array(node)
          with_comments(node) do |value|
            if (anchor = node.anchor)
              @q.text("&#{anchor} ")
            end

            if value.empty?
              @q.text("[]")
            else
              visit_array_contents(value)
            end
          end
        end

        # Visit a HashNode.
        def visit_hash(node)
          with_comments(node) do |value|
            if (anchor = node.anchor)
              @q.text("&#{anchor}")
            end

            if value.empty?
              @q.text(" ") if anchor
              @q.text("{}")
            else
              @q.breakable if anchor
              visit_hash_contents(value)
            end
          end
        end

        # Visit an ObjectNode.
        def visit_object(node)
          with_comments(node) do |value|
            @q.text(Psych.dump(value, indentation: @q.indent)[/\A--- (.+)\n\z/m, 1]) # TODO
          end
        end

        # Visit an OmapNode.
        def visit_omap(node)
          with_comments(node) do |value|
            if (anchor = node.anchor)
              @q.text("&#{anchor} ")
            end

            @q.text("!!omap")
            @q.breakable

            visit_array_contents(value)
          end
        end

        # Visit a SetNode.
        def visit_set(node)
          with_comments(node) do |value|
            if (anchor = node.anchor)
              @q.text("&#{anchor} ")
            end

            @q.text("!set")
            @q.breakable

            visit_hash_contents(node.value)
          end
        end

        # Visit a StringNode.
        alias visit_string visit_object

        private

        # Shortcut to visit a node by passing this visitor to the accept method.
        def visit(node)
          node.accept(self)
        end

        # Visit the elements within an array.
        def visit_array_contents(contents)
          @q.seplist(contents, -> { @q.breakable }) do |element|
            @q.text("-")
            next if element.is_a?(NilNode)

            @q.text(" ")
            @q.nest(2) { visit(element) }
          end
        end

        # Visit the key/value pairs within a hash.
        def visit_hash_contents(contents)
          @q.seplist(contents, -> { @q.breakable }) do |key, value|
            inlined = false

            case key
            when NilNode
              @q.text("! ''")
            when ArrayNode, HashNode, OmapNode, SetNode
              if key.anchor.nil?
                @q.text("? ")
                @q.nest(2) { visit(key) }
                @q.breakable
                inlined = true
              else
                visit(key)
              end
            when AliasNode, ObjectNode
              visit(key)
            when StringNode
              if key.value.include?("\n")
                @q.text("? ")
                visit(key)
                @q.breakable
                inlined = true
              else
                visit(key)
              end
            end

            @q.text(":")

            case value
            when NilNode
              # skip
            when OmapNode, SetNode
              @q.text(" ")
              @q.nest(2) { visit(value) }
            when ArrayNode
              if value.value.empty?
                @q.text(" []")
              elsif inlined || value.anchor
                @q.text(" ")
                @q.nest(2) { visit(value) }
              else
                @q.breakable
                visit(value)
              end
            when HashNode
              if value.value.empty?
                @q.text(" {}")
              elsif inlined || value.anchor
                @q.text(" ")
                @q.nest(2) { visit(value) }
              else
                @q.nest(2) do
                  @q.breakable
                  visit(value)
                end
              end
            when AliasNode, ObjectNode, StringNode
              @q.text(" ")
              @q.nest(2) { visit(value) }
            end
          end
        end

        # Print out the leading and trailing comments of a node, as well as
        # yielding the value of the node to the block.
        def with_comments(node)
          if (comments = node.comments) && (leading = comments.leading).any?
            line = nil

            leading.each do |comment|
              while line && line < comment.start_line
                @q.breakable
                line += 1
              end

              @q.text(comment.value)
              line = comment.end_line
            end

            @q.breakable
          end

          yield node.value

          if comments && (trailing = comments.trailing).any?
            line = nil
            index = 0

            if trailing[0].inline?
              inline_comment = trailing[0]
              index += 1

              @q.trailer { @q.text(" "); @q.text(inline_comment.value) }
              line = inline_comment.end_line
            end

            trailing[index..-1].each do |comment|
              if line.nil?
                @q.breakable
              else
                while line < comment.start_line
                  @q.breakable
                  line += 1
                end
              end

              @q.text(comment.value)
              line = comment.end_line
            end
          end
        end
      end

      # This is a specialized pretty printer that knows how to format trailing
      # comment.
      class Formatter < PP
        def breakable(sep = " ", width = sep.length)
          (current_trailers = trailers).each(&:call)
          current_trailers.clear
          super(sep, width)
        end

        # These are blocks in the doc tree that should be flushed whenever we
        # are about to flush a breakable.
        def trailers
          @trailers ||= []
        end

        # Register a block to be called when the next breakable is flushed.
        def trailer(&block)
          trailers << block
        end
      end

      # Initialize a new emitter with the given io and options.
      def initialize(io, options)
        @io = io || $stdout
        @options = options
        @started = false

        # These three instance variables are used to support dumping repeated
        # objects. When the same object is found more than once, we switch to
        # using an anchor and an alias.
        @object_nodes = {}.compare_by_identity
        @object_anchors = {}.compare_by_identity
        @object_anchor = 0
      end

      # This is the main entrypoint into this object. It is responsible for
      # pushing a new object onto the emitter, which is then represented as a
      # YAML document.
      def <<(object)
        if @started
          @io << "...\n---"
        else
          @io << "---"
          @started = true
        end

        if (node = dump(object)).is_a?(NilNode)
          @io << "\n"
        else
          q = Formatter.new(+"", 79, "\n") { |n| " " * n }

          if (node.is_a?(ArrayNode) || node.is_a?(HashNode)) && !node.value.empty?
            q.breakable
          else
            q.text(" ")
          end

          node.accept(Visitor.new(q))
          q.breakable
          q.current_group.break
          q.flush

          @io << q.output
        end
      end

      private

      # Walk through the given object and convert it into a tree of nodes.
      def dump(base_object, comments = nil)
        object = base_object

        if base_object.is_a?(CommentsObject) || base_object.is_a?(CommentsHash)
          object = base_object.__getobj__
          comments = base_object.psych_comments
        end

        if object.nil?
          NilNode.new(object, comments)
        elsif @object_nodes.key?(object)
          AliasNode.new(@object_nodes[object].anchor = (@object_anchors[object] ||= (@object_anchor += 1)), comments)
        else
          case object
          when Psych::Omap
            @object_nodes[object] = OmapNode.new(object.map { |(key, value)| HashNode.new({ dump(key) => dump(value) }, nil) }, comments)
          when Psych::Set
            @object_nodes[object] = SetNode.new(object.to_h { |key, value| [dump(key), dump(value)] }, comments)
          when Array
            @object_nodes[object] = ArrayNode.new(object.map { |element| dump(element) }, comments)
          when Hash
            dumped =
              if base_object.is_a?(CommentsHash)
                object.to_h { |key, value| [dump(key, base_object.psych_key_comments[key]), dump(value)] }
              else
                object.to_h { |key, value| [dump(key), dump(value)] }
              end

            @object_nodes[object] = HashNode.new(dumped, comments)
          when String
            StringNode.new(object, comments)
          else
            ObjectNode.new(object, comments)
          end
        end
      end
    end

    # A safe emitter is a subclass of the emitter that restricts the types of
    # objects that can be serialized.
    class SafeEmitter < Emitter
      DEFAULT_PERMITTED_CLASSES = {
        TrueClass => true,
        FalseClass => true,
        NilClass => true,
        Integer => true,
        Float => true,
        String => true,
        Array => true,
        Hash => true,
      }.compare_by_identity.freeze

      # Initialize a new safe emitter with the given io and options.
      def initialize(io, options)
        super(io, options)

        @permitted_classes = DEFAULT_PERMITTED_CLASSES.dup
        Array(options[:permitted_classes]).each do |klass|
          @permitted_classes[klass] = true
        end

        @permitted_symbols = {}.compare_by_identity
        Array(options[:permitted_symbols]).each do |symbol|
          @permitted_symbols[symbol] = true
        end

        @aliases = options.fetch(:aliases, false)
      end

      private

      # Dump the given object, ensuring that it is a permitted object.
      def dump(base_object, comments = nil)
        object = base_object

        if base_object.is_a?(CommentsObject) || base_object.is_a?(CommentsHash)
          object = base_object.__getobj__
        end

        if !@aliases && @object_nodes.key?(object)
          raise BadAlias, "Tried to dump an aliased object"
        end

        if Symbol === object
          if !@permitted_classes[Symbol] || !@permitted_symbols[object]
            raise DisallowedClass.new("dump", "Symbol(#{object.inspect})")
          end
        elsif !@permitted_classes[object.class]
          raise DisallowedClass.new("dump", object.class.name || object.class.inspect)
        end

        super
      end
    end

    # --------------------------------------------------------------------------
    # :section: Public API mirroring Psych
    # --------------------------------------------------------------------------

    # Create a new default parser.
    def self.parser
      Pure::Parser.new(TreeBuilder.new)
    end

    def self.parse(yaml, filename: nil, comments: false)
      parse_stream(yaml, filename: filename, comments: comments) do |node|
        return node
      end

      false
    end

    def self.parse_file(filename, fallback: false, comments: false)
      result = File.open(filename, "r:bom|utf-8") do |f|
        parse(f, filename: filename, comments: comments)
      end

      result || fallback
    end

    # Parse a YAML stream and return the root node.
    def self.parse_stream(yaml, filename: nil, comments: false, &block)
      if block_given?
        parser = Pure::Parser.new(Handlers::DocumentStream.new(&block))
        parser.parse(yaml, filename, comments: comments)
      else
        parser = self.parser
        parser.parse(yaml, filename, comments: comments)
        parser.handler.root
      end
    end

    def self.unsafe_load(yaml, filename: nil, fallback: false, symbolize_names: false, freeze: false, strict_integer: false, comments: false)
      result = parse(yaml, filename: filename, comments: comments)
      return fallback unless result

      result.to_ruby(symbolize_names: symbolize_names, freeze: freeze, strict_integer: strict_integer, comments: comments)
    end

    def self.safe_load(yaml, permitted_classes: [], permitted_symbols: [], aliases: false, filename: nil, fallback: nil, symbolize_names: false, freeze: false, strict_integer: false, comments: false)
      result = parse(yaml, filename: filename, comments: comments)
      return fallback unless result

      class_loader = ClassLoader::Restricted.new(permitted_classes.map(&:to_s), permitted_symbols.map(&:to_s))
      scanner = ScalarScanner.new(class_loader, strict_integer: strict_integer)
      visitor =
        if aliases
          Visitors::ToRuby.new(scanner, class_loader, symbolize_names: symbolize_names, freeze: freeze, comments: comments)
        else
          Visitors::NoAliasRuby.new(scanner, class_loader, symbolize_names: symbolize_names, freeze: freeze, comments: comments)
        end

      visitor.accept(result)
    end

    def self.load(yaml, permitted_classes: [Symbol], permitted_symbols: [], aliases: false, filename: nil, fallback: nil, symbolize_names: false, freeze: false, strict_integer: false, comments: false)
      safe_load(
        yaml,
        permitted_classes: permitted_classes,
        permitted_symbols: permitted_symbols,
        aliases: aliases,
        filename: filename,
        fallback: fallback,
        symbolize_names: symbolize_names,
        freeze: freeze,
        strict_integer: strict_integer,
        comments: comments
      )
    end

    def self.load_stream(yaml, filename: nil, fallback: [], comments: false, **kwargs)
      result =
        if block_given?
          parse_stream(yaml, filename: filename, comments: comments) do |node|
            yield node.to_ruby(**kwargs)
          end
        else
          parse_stream(yaml, filename: filename, comments: comments).children.map { |node| node.to_ruby(**kwargs) }
        end

      return fallback if result.is_a?(Array) && result.empty?
      result
    end

    def self.unsafe_load_file(filename, **kwargs)
      File.open(filename, "r:bom|utf-8") do |f|
        self.unsafe_load(f, filename: filename, **kwargs)
      end
    end

    def self.safe_load_file(filename, **kwargs)
      File.open(filename, "r:bom|utf-8") do |f|
        self.safe_load(f, filename: filename, **kwargs)
      end
    end

    def self.load_file(filename, **kwargs)
      File.open(filename, "r:bom|utf-8") do |f|
        self.load(f, filename: filename, **kwargs)
      end
    end

    # Dump an object to a YAML string.
    def self.dump(o, io = nil, options = {})
      if Hash === io
        options = io
        io = nil
      end

      real_io = io || StringIO.new
      emitter = Emitter.new(real_io, options)
      emitter << o
      io || real_io.string
    end

    # Dump an object to a YAML string, with restricted classes, symbols, and
    # aliases.
    def self.safe_dump(o, io = nil, options = {})
      if Hash === io
        options = io
        io = nil
      end

      real_io = io || StringIO.new
      emitter = SafeEmitter.new(real_io, options)
      emitter << o
      io || real_io.string
    end

    # Dump a stream of objects to a YAML string.
    def self.dump_stream(*objects)
      real_io = io || StringIO.new
      emitter = Emitter.new(real_io, {})
      objects.each { |object| emitter << object }
      io || real_io.string
    end
  end
end
