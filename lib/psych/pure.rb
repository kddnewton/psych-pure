# frozen_string_literal: true

require "delegate"
require "pp"
require "psych"
require "strscan"
require "stringio"

module Psych
  module Nodes
    class Scalar
      # The source of the scalar, as it was found in the input. This may be set
      # in order to be reused when dumping the object.
      attr_accessor :source
    end
  end

  # If Psych is older than 5.3, we need to modify the ScalarScanner to add the
  # parse_symbols parameter so that we can use it consistently when we
  # initialize it.
  if Psych::VERSION < "5.3"
    ScalarScanner.prepend(Module.new {
      def initialize(class_loader, strict_integer: false, parse_symbols: true)
        super(class_loader, strict_integer: strict_integer)
      end
    })
  end

  # A YAML parser written in Ruby.
  module Pure
    # An internal exception is an exception that should not have occurred. It is
    # effectively an assertion.
    class InternalException < Exception
      def initialize(message = "An internal exception occurred")
        super(message)
      end
    end

    # A source wraps the input string and provides methods to access line and
    # column information from a byte offset.
    class Source
      # The line index computed by the most recent call to #trim.
      attr_reader :trim_line

      def initialize(string)
        @string = string
        offsets = [0]
        @last_line_index = 0
        @last_line_offset = 0

        idx = 0
        while (found = string.index("\n", idx))
          offsets << (idx = found + 1)
        end

        offsets << string.bytesize if offsets.last != string.bytesize
        @line_offsets = offsets
      end

      # Trim trailing whitespace-only and comment-only lines from the given
      # offset. After calling, @trim_line holds the line index of the
      # returned offset so callers can avoid a redundant line() lookup.
      def trim(offset)
        offsets = @line_offsets
        string = @string
        l = line(offset)

        while l != 0 && offset == offsets[l]
          prev_start = offsets[l - 1]
          prev_end = offsets[l] - 1
          idx = prev_start
          idx += 1 while idx < prev_end && string.getbyte(idx) == 0x20 # space
          break unless idx >= prev_end || string.getbyte(idx) == 0x23 # #
          offset = prev_start
          l -= 1
        end

        @trim_line = l
        offset
      end

      def trim_comments(offset)
        offsets = @line_offsets
        string = @string
        l = line(offset)

        while l != 0 && offset == offsets[l]
          prev_start = offsets[l - 1]
          prev_end = offsets[l] - 1
          idx = prev_start
          idx += 1 while idx < prev_end && string.getbyte(idx) == 0x20 # space
          break unless idx < prev_end && string.getbyte(idx) == 0x23 # #
          offset = prev_start
          l -= 1
        end

        offset
      end

      def line(offset)
        # Fast path: linear scan forward from the last lookup position.
        # The parser generally moves forward through the input, so this
        # avoids the O(log n) bsearch in the common case.
        cached = @last_line_index
        offsets = @line_offsets

        if offset >= @last_line_offset
          max = offsets.size - 1
          while cached < max && offsets[cached + 1] <= offset
            cached += 1
          end

          @last_line_index = cached
          @last_line_offset = offsets[cached]
          cached
        else
          # Backward seek — linear scan backward from cached position
          while cached > 0 && offsets[cached] > offset
            cached -= 1
          end

          @last_line_index = cached
          @last_line_offset = offsets[cached]
          cached
        end
      end

      def column(offset, known_line = nil)
        offset - @line_offsets[known_line || line(offset)]
      end

      def point(offset)
        "line #{line(offset) + 1} column #{column(offset)}"
      end

    end

    # Represents a comment in the input.
    class Comment
      attr_reader :value

      def initialize(source, pos_start, pos_end, value, inline)
        @source = source
        @pos_start = pos_start
        @pos_end = pos_end
        @value = value
        @inline = inline
      end

      def inline?
        @inline
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

      def initialize_dup(other)
        super
        @leading = other.leading.dup
        @trailing = other.trailing.dup
      end

      def merge(other)
        @leading.concat(other.leading)
        @trailing.concat(other.trailing)
      end

      # Execute the given block without the leading comments being visible. This
      # is used when a node has already handled its child nodes' leading
      # comments, so they should not be processed again.
      def without_leading
        leading = @leading

        begin
          @leading = []
          yield
        ensure
          @leading = leading
        end
      end
    end

    # Wraps a Ruby object with its node from the source input.
    class LoadedObject < SimpleDelegator
      # The node associated with the object.
      attr_reader :psych_node

      # Whether or not this object has been modified. If it has, then we cannot
      # rely on the source formatting, and need to format it ourselves.
      attr_reader :dirty

      def initialize(object, psych_node)
        super(object)
        @psych_node = psych_node
        @dirty = false
      end

      def initialize_clone(obj, freeze: nil)
        super
        @psych_node = obj.psych_node.dup
      end

      def initialize_dup(obj)
        super
        @psych_node = obj.psych_node.dup
      end

      # Effectively implement the same method_missing as SimpleDelegator, but
      # additionally track whether or not the object has been mutated.
      ruby2_keywords def method_missing(name, *args, &block)
        takes_block = false
        target = self.__getobj__ { takes_block = true }

        if !takes_block && target_respond_to?(target, name, false)
          previous = target.dup
          result = target.__send__(name, *args, &block)

          @dirty = true unless previous.eql?(target)
          result
        else
          super(name, *args, &block)
        end
      end
    end

    # Wraps a Ruby array with its node from the source input.
    #
    # Every Array method falls into one of these buckets:
    #
    # * Additive (overridden, no dirty) — <<, push/append, unshift/prepend,
    #   insert, concat, fill. The relative gaps between existing elements'
    #   line numbers are still valid, so blank line preservation still works.
    #
    # * Replacement (overridden, conditional dirty) — []=. Only sets dirty
    #   when the array length changes (range-based deletion/insertion), not
    #   on simple element replacement.
    #
    # * Reordering (overridden, always dirty) — sort!, sort_by!, shuffle!,
    #   reverse!, rotate!. Line numbers become meaningless after reordering.
    #
    # * C-level fix (overridden) — compact, compact!. Array#compact uses a
    #   C-level nil check (NIL_P) that doesn't see through the delegator.
    #
    # * Removal (method_missing, dirty via dup+eql?) — delete, delete_at,
    #   pop, shift, reject!, select!, slice!, clear, replace, uniq!,
    #   flatten!, delete_if, keep_if. These fall through to LoadedObject's
    #   method_missing which sets dirty when the array actually changes.
    #
    # * Non-bang variants (return plain Array) — select, reject, map, sort,
    #   reverse, uniq, flatten, compact, +, -, &, |, etc. These return a
    #   new Array without array-level metadata, but the elements are shared
    #   references that still carry their comments.
    #
    # * Read-only (delegation, no mutation) — each, [], include?, length,
    #   first, last, etc. SimpleDelegator handles these automatically.
    class LoadedArray < LoadedObject
      # Additive — no dirty

      def <<(element)
        __getobj__ << element
        self
      end

      def push(*elements)
        __getobj__.push(*elements)
        self
      end

      alias append push

      def unshift(*elements)
        __getobj__.unshift(*elements)
        self
      end

      alias prepend unshift

      def insert(index, *elements)
        __getobj__.insert(index, *elements)
        self
      end

      def concat(*arrays)
        __getobj__.concat(*arrays)
        self
      end

      def fill(*args, &block)
        __getobj__.fill(*args, &block)
        self
      end

      # Replacement — conditional dirty

      def []=(index, *args)
        target = __getobj__
        previous = target.length
        result = target.[]=(index, *args)
        @dirty = true if target.length != previous
        result
      end

      # Reordering — always dirty

      def sort!(&block)
        __getobj__.sort!(&block)
        @dirty = true
        self
      end

      def sort_by!(&block)
        __getobj__.sort_by!(&block)
        @dirty = true
        self
      end

      def shuffle!(**kwargs)
        __getobj__.shuffle!(**kwargs)
        @dirty = true
        self
      end

      def reverse!
        __getobj__.reverse!
        @dirty = true
        self
      end

      def rotate!(count = 1)
        __getobj__.rotate!(count)
        @dirty = true
        self
      end

      # C-level fix — Array#compact uses NIL_P which doesn't see through
      # the delegator, so we implement nil detection manually.

      def compact
        __getobj__.reject { |element| nil_element?(element) }
      end

      def compact!
        target = __getobj__
        previous = target.length
        target.reject! { |element| nil_element?(element) }
        changed = target.length != previous
        @dirty = true if changed
        changed ? self : nil
      end

      private

      def nil_element?(element)
        element.nil? || (element.is_a?(LoadedObject) && element.__getobj__.nil?)
      end
    end

    # Wraps a Ruby hash with its node from the source input.
    class LoadedHash < SimpleDelegator
      class PsychKey
        attr_reader :key_node, :value_node

        def initialize(key_node, value_node)
          @key_node = key_node
          @value_node = value_node
        end

        def replace_key(key_node)
          @key_node = key_node
        end

        def replace_value(value_node)
          @value_node = value_node
        end
      end

      # The node associated with the hash.
      attr_reader :psych_node

      # The list of key/value pairs within the hash.
      attr_reader :psych_keys

      def initialize(object, psych_node)
        super(object)
        @psych_node = psych_node
        @psych_keys = []
      end

      def set!(key_node, value_node)
        @psych_keys << PsychKey.new(key_node, value_node)
        __getobj__[key_node.__getobj__] = value_node
      end

      def join!(key_node, value_node)
        @psych_keys << PsychKey.new(key_node, value_node)
        merge!(value_node)
      end

      def psych_assocs
        @psych_keys.map { |psych_key| [psych_key.key_node, psych_key.value_node] }
      end

      # Override Hash mutation methods to keep @psych_keys in sync.

      def initialize_clone(obj, freeze: nil)
        super
        @psych_node = obj.psych_node.dup
        @psych_keys = obj.psych_keys.map(&:dup)
      end

      def initialize_dup(obj)
        super
        @psych_node = obj.psych_node.dup
        @psych_keys = obj.psych_keys.map(&:dup)
      end

      def []=(key, value)
        super(key, value)

        if (psych_key = @psych_keys.reverse_each.find { |psych_key| psych_compare?(psych_key.key_node, key) })
          psych_key.replace_value(value)
        else
          @psych_keys << PsychKey.new(key, value)
        end

        value
      end

      alias store []=

      def clear
        super
        @psych_keys.clear

        self
      end

      def compact!
        mutated = false
        @psych_keys.each do |psych_key|
          if psych_unwrap(psych_key.value_node).nil?
            mutated = true
            delete(psych_unwrap(psych_key.key_node))
          end
        end

        self if mutated
      end

      def compact
        dup.compact!
      end

      def delete(key)
        result = super
        psych_delete(key)

        result
      end

      def delete_if(&block)
        super do |key, value|
          yield(key, psych_unwrap(value)).tap do |result|
            psych_delete(key) if result
          end
        end

        self
      end

      def except(*keys)
        dup.delete_if { |key, _| keys.include?(key) }
      end

      def filter!(&block)
        mutated = false
        super do |key, value|
          yield(key, psych_unwrap(value)).tap do |result|
            unless result
              psych_delete(key)
              mutated = true
            end
          end
        end

        self if mutated
      end

      def filter(&block)
        dup.filter!(&block)
      end

      def invert
        result = LoadedHash.new({}, @psych_node)
        each { |key, value| result[psych_unwrap(value)] = key }
        result
      end

      def keep_if(&block)
        super do |key, value|
          yield(key, psych_unwrap(value)).tap do |result|
            psych_delete(key) unless result
          end
        end

        self
      end

      alias select! keep_if

      def merge!(*others)
        super
        others.each do |other|
          if other.is_a?(LoadedHash)
            # When merging another LoadedHash, preserve its psych_keys to keep comments
            other.psych_keys.each do |psych_key|
              psych_delete(psych_unwrap(psych_key.key_node))
              @psych_keys << psych_key.dup
            end

            # Merge comments from the other hash's psych_node
            if other.psych_node&.comments?
              @psych_node.comments.merge(other.psych_node.comments)
            end
          else
            # Regular hash - just wrap keys and values
            other.each do |key, value|
              psych_delete(key)
              @psych_keys << PsychKey.new(key, value)
            end
          end
        end

        self
      end

      alias update merge!

      def merge(*others)
        dup.merge!(*others)
      end

      def reject!(&block)
        mutated = false
        super do |key, value|
          yield(key, psych_unwrap(value)).tap do |result|
            if result
              psych_delete(key)
              mutated = true
            end
          end
        end

        self if mutated
      end

      def reject(&block)
        dup.reject!(&block)
      end

      def replace(other)
        super

        @psych_keys.clear
        other.each { |key, value| @psych_keys << PsychKey.new(key, value) }

        self
      end

      def shift
        unless empty?
          key, value = super
          psych_delete(key)

          [key, value]
        end
      end

      def slice(*keys)
        dup.select! { |key, _| keys.include?(key) }
      end

      def transform_keys!(&block)
        super do |key|
          yield(key).tap do |result|
            @psych_keys
              .reverse_each
              .find { |psych_key| psych_compare?(psych_key.key_node, key) }
              &.replace_key(result)
          end
        end

        self
      end

      def transform_keys(&block)
        dup.transform_keys!(&block)
      end

      def transform_values!(&block)
        super do |value|
          yield(psych_unwrap(value)).tap do |result|
            @psych_keys
              .reverse_each
              .find { |psych_key| psych_compare?(psych_key.value_node, value) }
              &.replace_value(result)
          end
        end
      end

      def transform_values(&block)
        dup.transform_values!(&block)
      end

      private

      def psych_compare?(psych_node, value)
        if compare_by_identity?
          psych_unwrap(psych_node).equal?(value)
        else
          psych_unwrap(psych_node).eql?(value)
        end
      end

      def psych_delete(key)
        @psych_keys.reject! { |psych_key| psych_compare?(psych_key.key_node, key) }
      end

      def psych_unwrap(node)
        if node.is_a?(LoadedHash) || node.is_a?(LoadedObject)
          node.__getobj__
        else
          node
        end
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

          comment_start_line = comment.start_line
          comment_start_column = comment.start_column
          comment_end_line = comment.end_line
          comment_end_column = comment.end_column

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
        def start_document(version, tag_directives, implicit)
          node = Nodes::Document.new(version, tag_directives, implicit)
          set_start_location(node)
          push(node)
        end

        def end_document(implicit_end = !streaming?)
          @last.implicit_end = implicit_end
          node = pop
          set_end_location(node)
          attach_comments(node)
          @block.call(node)
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

        def initialize_dup(other)
          super
          @comments = other.comments.dup if other.comments?
        end

        def comments?
          defined?(@comments)
        end

        def to_ruby(symbolize_names: false, freeze: false, strict_integer: false, parse_symbols: true, comments: false)
          Visitors::ToRuby.create(symbolize_names: symbolize_names, freeze: freeze, strict_integer: strict_integer, parse_symbols: parse_symbols, comments: comments).accept(self)
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
            case result
            when LoadedObject, LoadedHash
              # skip
            else
              result =
                if result.is_a?(Array)
                  LoadedArray.new(result, node)
                else
                  LoadedObject.new(result, node)
                end
            end
          end

          result
        end

        private

        def revive_hash(hash, node, tagged = false)
          return super unless @comments

          revived = LoadedHash.new(hash, node)
          node.children.each_slice(2) do |key_node, value_node|
            key = accept(key_node)
            value = accept(value_node)

            if key == "<<" && key_node.tag != "tag:yaml.org,2002:str"
              case value_node
              when Nodes::Alias, Nodes::Mapping
                begin
                  # h1:
                  #   <<: *h2
                  #   <<: { k: v }
                  revived.join!(key, value)
                rescue TypeError
                  # a: &a [1, 2, 3]
                  # h: { <<: *a }
                  revived.set!(key, value)
                end
              when Nodes::Sequence
                # h1:
                #   <<: [*h2, *h3]
                begin
                  temporary = {}
                  value.reverse_each { |value| temporary.merge!(value) }
                rescue TypeError
                  revived.set!(key, value)
                else
                  value_node.children.zip(value).reverse_each do |(child_value_node, child_value)|
                    revived.join!(key, child_value)
                  end
                end
              else
                # k: v
                revived.set!(key, value)
              end
            else
              if !tagged && @symbolize_names && key.is_a?(String)
                key = key.to_sym
              elsif !@freeze
                key = deduplicate(key)
              end

              revived.set!(key, value)
            end
          end

          revived
        end
      end

      # Extend the ToRuby singleton to be able to pass the comments option.
      module ToRubySingleton
        def create(symbolize_names: false, freeze: false, strict_integer: false, parse_symbols: true, comments: false)
          class_loader = ClassLoader.new
          scanner = ScalarScanner.new(class_loader, strict_integer: strict_integer, parse_symbols: parse_symbols)
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

    # The parser is responsible for taking a YAML string and converting it into
    # a series of events that can be used by the consumer.
    class Parser < StringScanner
      # A stack of contexts that the parser is currently within. We use this to
      # decorate error messages with the context in which they occurred.
      class Context
        def initialize
          @contexts = []
          @deepest = nil
          @deepest_depth = 0
        end

        def syntax_error(source, filename, pos, message)
          stack = @contexts.empty? ? @deepest : @contexts
          if stack && !stack.empty?
            pos = stack[-2]
            message = "#{message}\nwithin:\n"
            idx = 0
            while idx < stack.size
              message << " #{format_entry(source, stack[idx], stack[idx + 1], stack[idx + 2])}\n"
              idx += 3 # each entry uses 3 array slots [type, pos, extra]
            end
          end

          SyntaxError.new(filename, source.line(pos), source.column(pos), pos, message, nil)
        end

        def within_block_mapping(pos, indent, &block)
          within(:block_mapping, pos, indent, &block)
        end

        def within_block_sequence(pos, indent, &block)
          within(:block_sequence, pos, indent, &block)
        end

        def within_double_quoted_scalar(pos, &block)
          within(:double_quoted_scalar, pos, nil, &block)
        end

        def within_flow_mapping(pos, context, &block)
          within(:flow_mapping, pos, context, &block)
        end

        def within_flow_sequence(pos, context, &block)
          within(:flow_sequence, pos, context, &block)
        end

        private

        def within(type, pos, extra)
          push_context(type, pos, extra)
          begin
            yield
          ensure
            pop_context
          end
        end

        # Push a context entry onto the stack. Each entry is stored as three
        # consecutive elements [type, pos, extra] in a flat array to avoid
        # allocating an object per context frame.
        def push_context(type, pos, extra)
          contexts = @contexts
          contexts.push(type, pos, extra)

          if (new_depth = contexts.length) > @deepest_depth
            @deepest_depth = new_depth
            @deepest = nil
          end
        end

        # Pop a context entry from the stack. Before popping, snapshot the
        # stack if this is the deepest point we've reached — this preserves
        # context for error messages even after unwinding.
        def pop_context
          contexts = @contexts
          if !@deepest && contexts.length <= @deepest_depth
            @deepest = contexts.dup
          end
          contexts.pop
          contexts.pop
          contexts.pop
        end

        def format_entry(source, type, pos, extra)
          case type
          when :block_mapping
            "block mapping at #{source.point(pos)}#{extra == -1 ? "" : " (indent=#{extra})"}"
          when :block_sequence
            "block sequence at #{source.point(pos)}#{extra == -1 ? "" : " (indent=#{extra})"}"
          when :double_quoted_scalar
            "double quoted scalar at #{source.point(pos)}"
          when :flow_mapping
            "flow mapping at #{source.point(pos)} (context=#{extra})"
          when :flow_sequence
            "flow sequence at #{source.point(pos)} (context=#{extra})"
          end
        end
      end

      # Initialize a new parser with the given source string.
      def initialize(handler)
        super("")

        # These are used to track the current state of the parser.
        @filename = nil
        @source = nil

        # The handler is the consumer of the events generated by the parser.
        @handler = handler

        # This functions as a list of temporary lists of events that may be
        # flushed into the handler if current context is matched.
        @events_cache = []
        @events_cache_marks = []
        @events_cache_depth = 0

        # Document start/end state. These are deferred and flushed lazily —
        # the document start is emitted when the first content event arrives,
        # and the document end is emitted when the next document starts.
        @doc_start_pos = nil
        @doc_start_version = nil
        @doc_start_implicit = true
        @doc_end_pos = nil
        @doc_end_implicit = true

        # Each document gets its own set of tags. This is a mapping of tag
        # handles to tag prefixes.
        @tag_directives = nil

        # When a tag property is parsed, it is stored here until it can be
        # flushed into the next event.
        @tag = nil

        # When a tag handle is parsed, it is stored here until the tag prefix
        # is parsed and the full tag can be resolved.
        @tag_handle = nil

        # When an anchor is parsed, it is stored here until it can be flushed
        # into the next event.
        @anchor = nil

        # In a bare document, explicit document starts (---) and ends (...) are
        # disallowed. In that case we need to check for those delimiters.
        @in_bare_document = false
        @check_forbidden = false

        # In a literal or folded scalar, we need to track that state in order to
        # insert the correct plain text prefix.
        @in_scalar = false
        @text_prefix = +""

        # This parser can optionally parse comments and attach them to the
        # resulting tree, if the option is passed.
        @comments = nil

        # The context of the parser at any given time, which is used to decorate
        # error messages to make it easier to find the specific location where
        # they occurred.
        @context = Context.new
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

        # Set StringScanner's source (used by skip/match/eos?) and keep a
        # direct reference for raw byte access (getbyte/byteslice) which
        # bypasses StringScanner for performance-critical paths.
        self.string = yaml
        @string = yaml
        @filename = filename
        @source = Source.new(yaml)
        @comments = {} if comments

        # Precompute positions where --- or ... appear at start of a line
        # followed by whitespace or end of string. These are forbidden content
        # positions in bare documents.
        @forbidden_content = {}
        yaml.scan(/^(?:---|\.\.\.)(?=[\s]|\z)/m) { @forbidden_content[$~.begin(0)] = true }
        @has_forbidden_content = !@forbidden_content.empty?

        parse_l_yaml_stream
        @comments = nil if comments
        true
      end

      private

      # Raise a syntax error with the given message.
      def raise_syntax_error(message)
        raise @context.syntax_error(@source, @filename, pos, message)
      end

      # ------------------------------------------------------------------------
      # :section: Parsing helpers
      # ------------------------------------------------------------------------

      # In certain cirumstances, we need to determine the indent based on the
      # content that follows the current position. This method implements that
      # logic.
      def detect_indent(n)
        pos = self.pos
        in_seq = pos > 0 && case @string.getbyte(pos - 1); when 0x2D, 0x3F, 0x3A then true; end # - ? :

        # Scan past lines that are empty or comment-only to find the
        # first content line, then measure its leading spaces.
        idx = pos
        len = @string.bytesize
        has_pre = false

        while idx < len
          # Count leading spaces on this line
          line_start = idx
          idx += 1 while idx < len && @string.getbyte(idx) == 0x20

          b = idx < len ? @string.getbyte(idx) : nil
          if b == 0x0A
            # Empty line (spaces only) — skip
            has_pre = true
            idx += 1
          elsif b == 0x23
            # Comment line — skip past newline
            has_pre = true
            idx += 1 while idx < len && @string.getbyte(idx) != 0x0A
            idx += 1 if idx < len
          else
            # Content line — measure indent
            m = idx - line_start
            if in_seq && !has_pre
              m += 1 if n == -1
            else
              m -= n
            end
            return m < 0 ? 0 : m
          end
        end

        # Only empty/comment lines remain
        0
      end

      # This is a convenience method used to retrieve a segment of the string
      # that was just matched by the scanner. It takes a position and returns
      # the input string from that position to the current scanner position.
      def from(pos)
        @string.byteslice(pos, self.pos - pos)
      end

      # This is the only way that the scanner is advanced. It checks if the
      # given value matches the current position (either with a string or
      # regular expression). If it does, it advances the scanner and returns
      # true. If it does not, it returns false.
      def match(value)
        return false if @check_forbidden && @forbidden_content[pos]
        skip(value)
      end

      # This is effectively the same as match, except that it does not advance
      # the scanner if the given match is found.
      def peek_ahead
        pos_start = pos
        result = try { yield }
        self.pos = pos_start
        result
      end

      # In the grammar when a rule has rule+, it means it should match one or
      # more times. This is a convenience method that implements that logic by
      # attempting to match the given block one or more times.
      def plus
        return false unless yield
        pos_current = pos
        pos_current = pos while yield && (pos != pos_current)
        true
      end

      # In the grammar when a rule has rule*, it means it should match zero or
      # more times. This is a convenience method that implements that logic by
      # attempting to match the given block zero or more times.
      def star
        pos_current = pos
        pos_current = pos while yield && (pos != pos_current)
        true
      end

      # True if the scanner it at the beginning of the string, the end of the
      # string, or the previous character was a newline.
      def start_of_line?
        (p = pos) == 0 ||
          @string.getbyte(p - 1) == 0x0A ||
          eos?
      end

      # This is our main backtracking mechanism. It attempts to parse forward
      # using the given block and return true. If it fails, it backtracks to the
      # original position and returns false.
      def try
        pos_start = pos
        yield || (self.pos = pos_start; false)
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
        if @doc_end_pos
          comments_flush
          l = @source.line(@doc_end_pos)
          c = @source.column(@doc_end_pos, l)
          @handler.event_location(l, c, l, c)
          @handler.end_document(@doc_end_implicit)
          reset_document_state
        end
      end

      # Reset document state to prepare for parsing the next document.
      # Called at the start of the stream and after each document end.
      def reset_document_state
        @doc_start_pos = pos
        @doc_start_version = nil
        @doc_start_implicit = true
        @tag_directives = {}
        @doc_end_pos = nil
        @doc_end_implicit = true
      end

      # Push a marker onto the events cache. Events added after this point
      # can be discarded or flushed as a group.
      def events_cache_push
        @events_cache_marks << @events_cache.size
        @events_cache_depth += 1
      end

      # Pop events added since the last marker and return them as an array.
      def events_cache_pop
        mark = @events_cache_marks.pop or raise InternalException
        @events_cache_depth -= 1
        @events_cache.slice!(mark..)
      end

      # Get the anchor and tag from the first event at the current marker
      # level, then discard all events at this level. Used to recover
      # properties when a speculative parse fails.
      def events_cache_pop_first_properties
        mark = @events_cache_marks.pop or raise InternalException
        @events_cache_depth -= 1
        entry = @events_cache[mark]
        @events_cache.pop while @events_cache.size > mark
        # Start event arrays: [type, pos_start, pos_end, style, anchor, tag]
        [entry[4], entry[5]]
      end

      # Discard events added since the last marker.
      def events_cache_discard
        mark = @events_cache_marks.pop or raise InternalException
        @events_cache_depth -= 1
        # Truncate to the mark position. pop without args returns the
        # element itself (no array allocation), unlike slice! or pop(n).
        @events_cache.pop while @events_cache.size > mark
        nil
      end

      # Flush events from the current marker level. If there's a parent
      # marker, the events are already in the flat array — just remove
      # the marker. If this is the top level, emit all events to the handler.
      def events_cache_flush
        mark = @events_cache_marks.pop or raise InternalException
        @events_cache_depth -= 1

        if @events_cache_depth == 0
          # Top level: emit events to handler and clear
          cache = @events_cache
          idx = mark
          len = cache.size

          while idx < len
            case (entry = cache[idx])[0]
            when :fast_scalar
              emit_pending_document_start
              accept_fast_scalar(entry[1], entry[2])
            when :scalar
              emit_pending_document_start
              accept_scalar(entry[1], entry[2], entry[3], entry[4], entry[5], entry[6], entry[7])
            when :mapping_start
              emit_pending_document_start
              accept_mapping_start(entry[1], entry[2], entry[3], entry[4], entry[5])
            when :mapping_end
              accept_mapping_end(entry[1], entry[2])
            when :sequence_start
              emit_pending_document_start
              accept_sequence_start(entry[1], entry[2], entry[3], entry[4], entry[5])
            when :sequence_end
              accept_sequence_end(entry[1], entry[2])
            when :alias
              emit_pending_document_start
              accept_alias(entry[1], entry[2], entry[3])
            end
            idx += 1
          end

          if mark == 0
            cache.clear
          else
            cache.pop while cache.size > mark
          end
        end

        # If not top level, events stay in the flat array — they belong
        # to the parent scope now. Nothing to do.
      end

      # Push a string entry into the events cache. Used for literal/folded
      # scalar lines that are collected and joined during scalar parsing.
      def events_push(string)
        @events_cache << string
      end

      # Emit the pending document start event if one exists. Called before
      # the first content event (mapping, sequence, or scalar).
      def emit_pending_document_start
        if @doc_start_pos
          l = @source.line(@doc_start_pos)
          c = @source.column(@doc_start_pos, l)
          @handler.event_location(l, c, l, c)
          @handler.start_document(@doc_start_version, @tag_directives.to_a, @doc_start_implicit)
          @doc_start_pos = nil
          @doc_end_pos = pos
          @doc_end_implicit = true
        end
      end

      # --- Emit methods ---
      # Each emit method pushes a tagged array to the cache when inside a
      # try block, or emits directly to the handler when at the top level.
      # This avoids object allocations on the hot path.

      def emit_mapping_start(pos_start, style, pos_end = pos_start)
        anchor = @anchor; @anchor = nil
        tag = @tag; @tag = nil
        if @events_cache_depth > 0
          @events_cache << [:mapping_start, pos_start, pos_end, style, anchor, tag]
        else
          emit_pending_document_start
          accept_mapping_start(pos_start, pos_end, style, anchor, tag)
        end
      end

      def emit_mapping_end(pos_start, pos_end = pos_start)
        if @events_cache_depth > 0
          @events_cache << [:mapping_end, pos_start, pos_end]
        else
          accept_mapping_end(pos_start, pos_end)
        end
      end

      def emit_sequence_start(pos_start, style, pos_end = pos_start)
        anchor = @anchor; @anchor = nil
        tag = @tag; @tag = nil
        if @events_cache_depth > 0
          @events_cache << [:sequence_start, pos_start, pos_end, style, anchor, tag]
        else
          emit_pending_document_start
          accept_sequence_start(pos_start, pos_end, style, anchor, tag)
        end
      end

      def emit_sequence_end(pos_start, pos_end = pos_start)
        if @events_cache_depth > 0
          @events_cache << [:sequence_end, pos_start, pos_end]
        else
          accept_sequence_end(pos_start, pos_end)
        end
      end

      def emit_scalar(pos_start, pos_end, value, source_str, style)
        anchor = @anchor; @anchor = nil
        tag = @tag; @tag = nil
        if @events_cache_depth > 0
          @events_cache << [:scalar, pos_start, pos_end, value, source_str, style, anchor, tag]
        else
          emit_pending_document_start
          accept_scalar(pos_start, pos_end, value, source_str, style, anchor, tag)
        end
      end

      def emit_fast_scalar(pos_start, pos_end)
        if @events_cache_depth > 0
          @events_cache << [:fast_scalar, pos_start, pos_end]
        else
          emit_pending_document_start
          accept_fast_scalar(pos_start, pos_end)
        end
      end

      def emit_alias(pos_start, pos_end, name)
        if @events_cache_depth > 0
          @events_cache << [:alias, pos_start, pos_end, name]
        else
          emit_pending_document_start
          accept_alias(pos_start, pos_end, name)
        end
      end

      def emit_stream_start(p)
        l = @source.line(p)
        c = @source.column(p, l)
        @handler.event_location(l, c, l, c)
        @handler.start_stream(Psych::Parser::UTF8)
      end

      def emit_stream_end(p)
        l = @source.line(p)
        c = @source.column(p, l)
        @handler.event_location(l, c, l, c)
        @handler.end_stream
      end

      # --- Accept methods ---
      # These perform the actual handler calls with line/column computation.

      def accept_mapping_start(pos_start, pos_end, style, anchor, tag)
        sl = @source.line(pos_start)
        sc = @source.column(pos_start, sl)
        if pos_start == pos_end
          @handler.event_location(sl, sc, sl, sc)
        else
          el = @source.line(pos_end)
          @handler.event_location(sl, sc, el, @source.column(pos_end, el))
        end
        @handler.start_mapping(anchor, tag, style == Nodes::Mapping::BLOCK, style)
      end

      def accept_mapping_end(pos_start, pos_end)
        sl = @source.line(pos_start)
        effective_end = @source.trim(pos_end)
        if pos_start == effective_end
          c = @source.column(pos_start, sl)
          @handler.event_location(sl, c, sl, c)
        else
          el = @source.trim_line
          @handler.event_location(sl, @source.column(pos_start, sl), el, @source.column(effective_end, el))
        end
        @handler.end_mapping
      end

      def accept_sequence_start(pos_start, pos_end, style, anchor, tag)
        sl = @source.line(pos_start)
        sc = @source.column(pos_start, sl)
        if pos_start == pos_end
          @handler.event_location(sl, sc, sl, sc)
        else
          el = @source.line(pos_end)
          @handler.event_location(sl, sc, el, @source.column(pos_end, el))
        end
        @handler.start_sequence(anchor, tag, style == Nodes::Sequence::BLOCK, style)
      end

      def accept_sequence_end(pos_start, pos_end)
        sl = @source.line(pos_start)
        effective_end = @source.trim(pos_end)
        if pos_start == effective_end
          c = @source.column(pos_start, sl)
          @handler.event_location(sl, c, sl, c)
        else
          el = @source.trim_line
          @handler.event_location(sl, @source.column(pos_start, sl), el, @source.column(effective_end, el))
        end
        @handler.end_sequence
      end

      def accept_scalar(pos_start, pos_end, value, source_str, style, anchor, tag)
        sl = @source.line(pos_start)
        effective_end = @source.trim(pos_end)
        el = @source.trim_line
        @handler.event_location(sl, @source.column(pos_start, sl), el, @source.column(effective_end, el))

        event =
          @handler.scalar(
            value,
            anchor,
            tag,
            (!tag || tag == "!") && (style == Nodes::Scalar::PLAIN),
            (!tag || tag == "!") && (style != Nodes::Scalar::PLAIN),
            style
          )

        event.source = source_str if event.is_a?(Nodes::Scalar)
        event
      end

      def accept_fast_scalar(pos_start, pos_end)
        sl = @source.line(pos_start)
        sc = @source.column(pos_start, sl)
        ec = @source.column(pos_end, sl)
        @handler.event_location(sl, sc, sl, ec)

        value = @string.byteslice(pos_start, pos_end - pos_start)
        event = @handler.scalar(value, nil, nil, true, false, Nodes::Scalar::PLAIN)
        event.source = value if event.is_a?(Nodes::Scalar)
        event
      end

      def accept_alias(pos_start, pos_end, name)
        sl = @source.line(pos_start)
        sc = @source.column(pos_start, sl)
        el = @source.line(pos_end)
        @handler.event_location(sl, sc, el, @source.column(pos_end, el))
        @handler.alias(name)
      end

      # ------------------------------------------------------------------------
      # :section: Grammar rules
      # ------------------------------------------------------------------------

      # [027]
      # nb-char ::=
      #   c-printable - b-char - c-byte-order-mark
      # = [\t\x20-\x7E\u0085\u00A0-\uD7FF\uE000-\uFEFE\uFF00-\uFFFD\u{10000}-\u{10FFFF}]

      # [023]
      # c-flow-indicator ::=
      #   ',' | '[' | ']' | '{' | '}'

      # [028]
      # b-break ::=
      #   ( b-carriage-return b-line-feed )
      #   | b-carriage-return
      #   | b-line-feed
      def parse_b_break
        skip(/\u{0A}|\u{0D}\u{0A}?/)
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
        pos_start = pos

        if match(/[\u{20}\u{09}]/)
          @text_prefix = from(pos_start) if @in_scalar
          true
        end
      end

      # [034]
      # ns-char ::=
      #   nb-char - s-white
      def parse_ns_char
        pos_start = pos
        if match(/[\x21-\x7E\u0085\u00A0-\uD7FF\uE000-\uFEFE\uFF00-\uFFFD\u{10000}-\u{10FFFF}]/)
          @text_prefix = from(pos_start) if @in_scalar
          true
        end
      end

      # [036]
      # ns-hex-digit ::=
      #   ns-dec-digit | [x:41-x:46] | [x:61-x:66]
      # [039]
      # ns-uri-char ::=
      #   '%' ns-hex-digit ns-hex-digit | ns-word-char | '#'
      #   | ';' | '/' | '?' | ':' | '@' | '&' | '=' | '+' | '$' | ','
      #   | '_' | '.' | '!' | '~' | '*' | ''' | '(' | ')' | '[' | ']'
      def parse_ns_uri_char
        try { match("%") && match(/[0-9a-fA-F]/) && match(/[0-9a-fA-F]/) } ||
          match(/[\u{30}-\u{39}\u{41}-\u{5A}\u{61}-\u{7A}\-#;\/?:@&=+$,_.!~*'\(\)\[\]]/)
      end

      # [040]
      # ns-tag-char ::=
      #   ns-uri-char - '!' - c-flow-indicator
      def parse_ns_tag_char
        pos_start = pos

        if parse_ns_uri_char
          pos_end = pos
          self.pos = pos_start

          if match("!") || match(/[,\[\]{}]/)
            self.pos = pos_start
            false
          else
            self.pos = pos_end
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
          try { match("\\x") && match(/[0-9a-fA-F]/) && match(/[0-9a-fA-F]/) } ||
          try { match("\\u") && 4.times.all? { match(/[0-9a-fA-F]/) } } ||
          try { match("\\U") && 8.times.all? { match(/[0-9a-fA-F]/) } }
      end

      # [063]
      # s-indent(n) ::=
      #   s-space{n}
      INDENT_STRINGS = Hash.new { |_, n| " " * n }
      (0...100).each { |n| INDENT_STRINGS[n] = " " * n }
      private_constant :INDENT_STRINGS

      def parse_s_indent(n)
        skip(INDENT_STRINGS[n])
      end

      # [031]
      # s-space ::=
      #   x:20
      #
      # [064]
      # s-indent(<n) ::=
      #   s-space{m} <where_m_<_n>
      def parse_s_indent_lt(n)
        pos_start = pos
        skip(/\u{20}*/)

        if (pos - pos_start) < n
          true
        else
          self.pos = pos_start
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
        pos_start = pos
        skip(/\u{20}*/)

        if (pos - pos_start) <= n
          true
        else
          self.pos = pos_start
          false
        end
      end

      # [066]
      # s-separate-in-line ::=
      #   s-white+ | <start_of_line>
      def parse_s_separate_in_line
        skip(/[ \t]+/) || start_of_line?
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
          parse_b_l_folded(n, :flow_in) &&
            !(@check_forbidden && @forbidden_content[pos]) &&
            parse_s_flow_line_prefix(n)
        end
      end

      # [075]
      # c-nb-comment-text ::=
      #   '#' nb-char*
      def parse_c_nb_comment_text(inline)
        return false unless skip("#")

        pos = self.pos - 1
        skip(/[\t\x20-\x7E\u0085\u00A0-\uD7FF\uE000-\uFEFE\uFF00-\uFFFD\u{10000}-\u{10FFFF}]*/)

        @comments[pos] ||= Comment.new(@source, pos, self.pos, from(pos), inline) if @comments
        true
      end

      # [076]
      # b-comment ::=
      #   b-non-content | <end_of_file>
      def parse_b_comment
        parse_b_non_content || eos?
      end

      # [077]
      # s-b-comment ::=
      #   ( s-separate-in-line
      #   c-nb-comment-text? )?
      #   b-comment
      def parse_s_b_comment
        try do
          if parse_s_separate_in_line
            parse_c_nb_comment_text(true)
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
          match(/[\x21-\x7E\u0085\u00A0-\uD7FF\uE000-\uFEFE\uFF00-\uFFFD\u{10000}-\u{10FFFF}]+/) &&
            star { try { parse_s_separate_in_line && match(/[\x21-\x7E\u0085\u00A0-\uD7FF\uE000-\uFEFE\uFF00-\uFFFD\u{10000}-\u{10FFFF}]+/) } }
        end
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
        pos_start = pos

        if try {
          plus { match(/[\u{30}-\u{39}]/) } &&
          match(".") &&
          plus { match(/[\u{30}-\u{39}]/) }
        } then
          raise_syntax_error("Multiple %YAML directives not allowed") if @doc_start_version
          @doc_start_version = from(pos_start).split(".").map { |digits| digits.to_i(10) }
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
        pos_start = pos

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
        pos_start = pos

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
        case @string.getbyte(pos)
        when 0x21 # ! — must be tag first
          try do
            if parse_c_ns_tag_property
              try { parse_s_separate(n, c) && parse_c_ns_anchor_property }
              true
            end
          end
        when 0x26 # & — must be anchor first
          try do
            if parse_c_ns_anchor_property
              try { parse_s_separate(n, c) && parse_c_ns_tag_property }
              true
            end
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
        return unless @string.getbyte(pos) == 0x21 # !
        pos_start = pos

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
      #
      # [102]
      # ns-anchor-char ::=
      #   ns-char - c-flow-indicator
      def parse_c_ns_anchor_property
        return unless @string.getbyte(pos) == 0x26 # &
        pos_start = pos

        if try { match("&") && match(/[\x21-\x2B\x2D-\x5A\x5C\x5E-\x7A\x7C\x7E\u0085\u00A0-\uD7FF\uE000-\uFEFE\uFF00-\uFFFD\u{10000}-\u{10FFFF}]+/) }
          @anchor = from(pos_start).byteslice(1..)
          true
        end
      end

      # [104]
      # c-ns-alias-node ::=
      #   '*' ns-anchor-name
      def parse_c_ns_alias_node
        return false unless @string.getbyte(pos) == 0x2A # '*'
        pos_start = pos
        if try { match("*") && match(/[\x21-\x2B\x2D-\x5A\x5C\x5E-\x7A\x7C\x7E\u0085\u00A0-\uD7FF\uE000-\uFEFE\uFF00-\uFFFD\u{10000}-\u{10FFFF}]+/) }
          emit_alias(pos_start, pos, from(pos_start).byteslice(1..))
          true
        end
      end

      # [105]
      # e-scalar ::=
      #   <empty>
      def parse_e_scalar
        emit_scalar(pos, pos, "", "", Nodes::Scalar::PLAIN)
        true
      end

      # [106]
      # e-node ::=
      #   e-scalar
      alias parse_e_node parse_e_scalar

      # [108]
      # ns-double-char ::=
      #   nb-double-char - s-white
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

      C_DOUBLE_QUOTED_ESCAPE_END1 = /\A\\\r?\n[ \t]*\z/
      C_DOUBLE_QUOTED_ESCAPE_END2 = /\A(?:[ \t]*\r?\n[ \t]*)+\z/
      C_DOUBLE_QUOTED_ESCAPE_END2_SUB = /[ \t]*\r?\n[ \t]*/

      # Combined pattern for c-ns-esc-char [062], line folding [073-076],
      # and hex escape sequences in double-quoted scalars.
      C_DOUBLE_QUOTED_GSUB = %r{(?:\r\n|\\\r?\n[ \t]*|(?:[ \t]*\r?\n[ \t]*)+|\\x([0-9a-fA-F]{2})|\\u([0-9a-fA-F]{4})|\\U([0-9a-fA-F]{8})|\\[\\ "/_0abefnrt\tvLNP])}

      private_constant :C_DOUBLE_QUOTED_ESCAPE_END1, :C_DOUBLE_QUOTED_ESCAPE_END2, :C_DOUBLE_QUOTED_ESCAPE_END2_SUB, :C_DOUBLE_QUOTED_GSUB

      # [109]
      # c-double-quoted(n,c) ::=
      #   '"' nb-double-text(n,c)
      #   '"'
      def parse_c_double_quoted(n, c)
        return unless @string.getbyte(pos) == 0x22 # "
        pos_start = pos

        @context.within_double_quoted_scalar(pos) do
          if try { skip("\"") && parse_nb_double_text(n, c) && skip("\"") }
            source = from(pos_start)
            value = source.byteslice(1...-1)
            value.gsub!(C_DOUBLE_QUOTED_GSUB) do |m|
              if $1 || $2 || $3
                ($1 || $2 || $3).to_i(16).chr(Encoding::UTF_8)
              elsif m.match?(C_DOUBLE_QUOTED_ESCAPE_END1)
                ""
              elsif m.match?(C_DOUBLE_QUOTED_ESCAPE_END2)
                m.sub(C_DOUBLE_QUOTED_ESCAPE_END2_SUB, "").gsub(C_DOUBLE_QUOTED_ESCAPE_END2_SUB, "\n").then { |r| r.empty? ? " " : r }
              else
                C_DOUBLE_QUOTED_UNESCAPES.fetch(m, m)
              end
            end

            emit_scalar(pos_start, pos, value, source, Nodes::Scalar::DOUBLE_QUOTED)
            true
          end
        end
      end

      # Bulk regex: matches runs of valid double-quoted chars (including escape
      # sequences) but not unescaped \ or " or line breaks.
      # [110]
      # nb-double-text(n,c) ::=
      #   ( c = flow-out => nb-double-multi-line(n) )
      #   ( c = flow-in => nb-double-multi-line(n) )
      #   ( c = block-key => nb-double-one-line )
      #   ( c = flow-key => nb-double-one-line )
      def parse_nb_double_text(n, c)
        case c
        when :block_key, :flow_key
          skip(/(?:[^\\"\n\r]|\\[0abt\tnvfre "\/\\N_LP]|\\x[0-9a-fA-F]{2}|\\u[0-9a-fA-F]{4}|\\U[0-9a-fA-F]{8})*/)
          true
        when :flow_in, :flow_out
          parse_nb_double_multi_line(n)
        else
          raise InternalException, c.inspect
        end
      end

      # [112]
      # s-double-escaped(n) ::=
      #   s-white* '\'
      #   b-non-content
      #   l-empty(n,flow-in)* s-flow-line-prefix(n)
      def parse_s_double_escaped(n)
        try do
          (skip(/[ \t]*/) || true) &&
            skip("\\") &&
            parse_b_non_content &&
            !(@check_forbidden && @forbidden_content[pos]) &&
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

      # Bulk regex: matches whitespace-separated non-whitespace double-quoted
      # chars (including escape sequences).
      # [114]
      # nb-ns-double-in-line ::=
      #   ( s-white* ns-double-char )*
      #
      # [115]
      # s-double-next-line(n) ::=
      #   s-double-break(n)
      #   ( ns-double-char nb-ns-double-in-line
      #   ( s-double-next-line(n) | s-white* ) )?
      def parse_s_double_next_line(n)
        try do
          if parse_s_double_break(n)
            try do
              skip(/\\[0abt\tnvfre "\/\\N_LP]|\\x[0-9a-fA-F]{2}|\\u[0-9a-fA-F]{4}|\\U[0-9a-fA-F]{8}|[\x21\x23-\x5B\x5D-\u{10FFFF}]/) &&
                (skip(/(?:[ \t]*(?:[^ \t\\"\n\r]|\\[0abt\tnvfre "\/\\N_LP]|\\x[0-9a-fA-F]{2}|\\u[0-9a-fA-F]{4}|\\U[0-9a-fA-F]{8}))*/) || true) &&
                (parse_s_double_next_line(n) || (skip(/[ \t]*/) || true))
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
          (skip(/(?:[ \t]*(?:[^ \t\\"\n\r]|\\[0abt\tnvfre "\/\\N_LP]|\\x[0-9a-fA-F]{2}|\\u[0-9a-fA-F]{4}|\\U[0-9a-fA-F]{8}))*/) || true) &&
            (parse_s_double_next_line(n) || (skip(/[ \t]*/) || true))
        end
      end

      # [117]
      # c-quoted-quote ::=
      #   ''' '''
      #
      # [118]
      # nb-single-char ::=
      #   c-quoted-quote | ( nb-json - ''' )
      #
      # [119]
      # ns-single-char ::=
      #   nb-single-char - s-white
      #
      # [120]
      # c-single-quoted(n,c) ::=
      #   ''' nb-single-text(n,c)
      #   '''
      def parse_c_single_quoted(n, c)
        return unless @string.getbyte(pos) == 0x27 # '
        pos_start = pos

        if try { skip("'") && parse_nb_single_text(n, c) && skip("'") }
          source = from(pos_start)
          value = source.byteslice(1...-1)
          value.gsub!(/[ \t]*(?:\r?\n[ \t]*)+/) { |m| (nl = m.count("\n")) == 1 ? " " : "\n" * (nl - 1) }
          value.gsub!("''", "'")
          emit_scalar(pos_start, pos, value, source, Nodes::Scalar::SINGLE_QUOTED)
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
        when :block_key, :flow_key
          skip(/(?:[^'\n\r]|'')*/)
          true
        when :flow_in, :flow_out
          parse_nb_single_multi_line(n)
        else
          raise InternalException, c.inspect
        end
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
              skip(/''|[\x21-\x26\x28-\u{10FFFF}]/) &&
                (skip(/(?:[ \t]*(?:[^ \t'\n\r]|''))*/) || true) &&
                (parse_s_single_next_line(n) || (skip(/[ \t]*/) || true))
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
          (skip(/(?:[ \t]*(?:[^ \t'\n\r]|''))*/) || true) &&
            (parse_s_single_next_line(n) || (skip(/[ \t]*/) || true))
        end
      end

      # [126]
      # ns-plain-first(c) ::=
      #   ( ns-char - c-indicator )
      #   | ( ( '?' | ':' | '-' )
      #   <followed_by_an_ns-plain-safe(c)> )
      def parse_ns_plain_first(c)
        case c
        when :flow_out, :block_key then match(/[^\s,\[\]{}#&*!|>'"%@`\uFEFF?:-]|[?:-](?=[^\s\uFEFF])/)
        when :flow_in, :flow_key then match(/[^\s,\[\]{}#&*!|>'"%@`\uFEFF?:-]|[?:-](?=[^\s,\[\]{}\uFEFF])/)
        end
      end

      # [127]
      # ns-plain-safe(c) ::=
      #   ( c = flow-out => ns-plain-safe-out )
      #   ( c = flow-in => ns-plain-safe-in )
      #   ( c = block-key => ns-plain-safe-out )
      #   ( c = flow-key => ns-plain-safe-in )
      def parse_ns_plain_safe(c)
        case c
        when :block_key, :flow_out
          parse_ns_char
        when :flow_in, :flow_key
          match(/[\x21-\x2B\x2D-\x5A\x5C\x5E-\x7A\x7C\x7E\u0085\u00A0-\uD7FF\uE000-\uFEFE\uFF00-\uFFFD\u{10000}-\u{10FFFF}]/)
        else
          raise InternalException, c.inspect
        end
      end

      # [129]
      # ns-plain-safe-in ::=
      #   ns-char - c-flow-indicator
      #
      # [130]
      # ns-plain-char(c) ::=
      #   ( ns-plain-safe(c) - ':' - '#' )
      #   | ( <an_ns-char_preceding> '#' )
      #   | ( ':' <followed_by_an_ns-plain-safe(c)> )
      def parse_ns_plain_char(c)
        try do
          pos_start = pos

          if parse_ns_plain_safe(c)
            pos_end = pos
            self.pos = pos_start

            if match(/[:#]/)
              false
            else
              self.pos = pos_end
              true
            end
          end
        end ||
        try do
          pos_start = pos
          self.pos -= 1

          was_ns_char = parse_ns_char
          self.pos = pos_start

          was_ns_char && match("#")
        end ||
        try do
          match(":") && peek_ahead { parse_ns_plain_safe(c) }
        end
      end

      # [132]
      # nb-ns-plain-in-line(c) ::=
      #   ( s-white*
      #   ns-plain-char(c) )*
      def parse_nb_ns_plain_in_line(c)
        case c
        when :flow_out, :block_key
          skip(/(?:[ \t]*(?:[^ \t\r\n:#\uFEFF]|:(?=[^ \t\r\n\uFEFF])|(?<=[^ \t\r\n])#))*/)
        when :flow_in, :flow_key
          skip(/(?:[ \t]*(?:[^ \t\r\n:#,\[\]{}\uFEFF]|:(?=[^ \t\r\n,\[\]{}\uFEFF])|(?<=[^ \t\r\n])#))*/)
        end
        true
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
            @context.within_flow_sequence(pos, c) do
              emit_sequence_start(pos - 1, Nodes::Sequence::FLOW, pos)

              parse_s_separate(n, c)
              parse_fast_flow_seq_entries || parse_ns_s_flow_seq_entries(n, parse_in_flow(c))

              if match("]")
                emit_sequence_end(pos - 1, pos)
                true
              end
            end
          end
        end
      end

      # --- Fast paths ---
      #
      # These methods short-circuit the recursive descent for common simple
      # cases (single-line plain scalars) to avoid method call overhead and
      # allocations on the hot path. Each collects entries speculatively and
      # bails (resetting pos) if anything non-trivial is encountered.
      #
      # The plain scalar regexps implement ns-plain-first [126] followed by
      # nb-ns-plain-in-line [132] from the YAML spec. The flow variants
      # exclude flow indicators (,[]{}) while the block variants do not.

      # Fast path for flow sequence entries: handles [plain1, plain2, ...]
      def parse_fast_flow_seq_entries
        return false if @anchor || @tag

        pos_start = pos

        # Quick check: first char must be a possible plain scalar start
        case @string.getbyte(pos)
        when 0x5D, 0x5B, 0x7B, 0x27, 0x22, 0x21, 0x26, 0x2A, 0x3F, nil # ] [ { ' " ! & * ?
          return false
        end

        # Collect entries first, only emit if the whole fast path succeeds.
        # Each entry is [value_start, value_end, value].
        entries = []

        loop do
          entry_start = pos
          unless skip(/(?:[^\s,\[\]{}#&*!|>'"%@`\uFEFF?:-]|[?:-](?=[^\s,\[\]{}\uFEFF]))(?:[ \t]*(?:[^ \t\r\n:#,\[\]{}\uFEFF]|:(?=[^ \t\r\n,\[\]{}\uFEFF])|(?<=[^ \t\r\n])#))*/)
            self.pos = pos_start
            return false
          end
          entry_end = pos
          entry_value = matched

          skip(/[ \t]*/)
          next_byte = @string.getbyte(pos)

          # If followed by ':' + space/flow-indicator/EOL, this is a flow pair — bail
          if next_byte == 0x3A # :
            case @string.getbyte(pos + 1)
            when 0x20, 0x09, 0x2C, 0x5D, 0x7D, 0x5B, 0x7B, 0x0A, 0x0D, nil # space tab , ] } [ { \n \r EOF
              self.pos = pos_start
              return false
            end
          end

          # If followed by newline, this is multi-line — bail
          case next_byte
          when 0x0A, 0x0D
            self.pos = pos_start
            return false
          end

          entries << entry_start << entry_end << entry_value

          case next_byte
          when 0x2C # ,
            self.pos += 1
            skip(/[ \t]*/)

            case @string.getbyte(pos)
            when 0x5D # ]
              break # Trailing comma before ]
            when 0x0A, 0x0D, 0x5B, 0x7B, 0x27, 0x22, 0x21, 0x26, 0x2A, 0x3F
              self.pos = pos_start
              return false # Bail on newline or non-plain-scalar start
            end
          else
            break
          end
        end

        # Must end with ] to be a valid fast path
        unless @string.getbyte(pos) == 0x5D # ]
          self.pos = pos_start
          return false
        end

        # Emit all collected entries
        idx = 0
        while idx < entries.size
          # [value_start, value_end, value]
          emit_scalar(entries[idx], entries[idx + 1], entries[idx + 2], entries[idx + 2], Nodes::Scalar::PLAIN)
          idx += 3
        end

        true
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

            if match(",")
              parse_s_separate(n, c)
              parse_ns_s_flow_seq_entries(n, c)
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
            @context.within_flow_mapping(pos, c) do
              emit_mapping_start(pos - 1, Nodes::Mapping::FLOW, pos)

              parse_s_separate(n, c)
              parse_fast_flow_map_entries || parse_ns_s_flow_map_entries(n, parse_in_flow(c))

              if match("}")
                emit_mapping_end(pos - 1, pos)
                true
              end
            end
          end
        end
      end

      # Fast path for flow mapping entries: handles {key: val, key: val, ...}
      # without going through the full recursive descent. Only handles
      # single-line mappings with plain scalar keys and values.
      def parse_fast_flow_map_entries
        return false if @anchor || @tag

        pos_start = pos

        # Quick check: first char must be a possible plain scalar start
        case @string.getbyte(pos)
        when 0x7D, 0x5B, 0x7B, 0x27, 0x22, 0x21, 0x26, 0x2A, 0x3F, nil # } [ { ' " ! & * ?
          return false
        end

        # Collect entries first, only emit if the whole fast path succeeds.
        # Each entry is [key_start, key_end, key, value_start, value_end, value].
        entries = []

        loop do
          entry_start = pos
          unless skip(/((?:[^\s,\[\]{}#&*!|>'"%@`\uFEFF?:-]|[?:-](?=[^\s,\[\]{}\uFEFF]))(?:[ \t]*(?:[^ \t\r\n:#,\[\]{}\uFEFF]|:(?=[^ \t\r\n,\[\]{}\uFEFF])|(?<=[^ \t\r\n])#))*):[ \t]+((?:[^\s,\[\]{}#&*!|>'"%@`\uFEFF?:-]|[?:-](?=[^\s,\[\]{}\uFEFF]))(?:[ \t]*(?:[^ \t\r\n:#,\[\]{}\uFEFF]|:(?=[^ \t\r\n,\[\]{}\uFEFF])|(?<=[^ \t\r\n])#))*)/)
            self.pos = pos_start
            return false
          end
          matched_key = self[1]
          matched_value = self[2]
          matched_end = pos

          skip(/[ \t]*/)
          next_byte = @string.getbyte(pos)

          # Bail on newline (multi-line flow)
          case next_byte
          when 0x0A, 0x0D
            self.pos = pos_start
            return false
          end

          entries << entry_start << entry_start + matched_key.bytesize << matched_key << matched_end - matched_value.bytesize << matched_end << matched_value

          case next_byte
          when 0x2C # ,
            self.pos += 1
            skip(/[ \t]*/)
            next_byte2 = @string.getbyte(pos)
            # Trailing comma before }
            break if next_byte2 == 0x7D # }
            # Bail on newline or non-plain-scalar start
            case next_byte2
            when 0x0A, 0x0D, 0x5B, 0x7B, 0x27, 0x22, 0x21, 0x26, 0x2A, 0x3F
              self.pos = pos_start
              return false
            end
          else
            break
          end
        end

        # Must end with } to be a valid fast path
        unless @string.getbyte(pos) == 0x7D # }
          self.pos = pos_start
          return false
        end

        # Emit all collected entries
        idx = 0
        while idx < entries.size
          # [key_start, key_end, key, value_start, value_end, value]
          emit_scalar(entries[idx], entries[idx + 1], entries[idx + 2], entries[idx + 2], Nodes::Scalar::PLAIN)
          emit_scalar(entries[idx + 3], entries[idx + 4], entries[idx + 5], entries[idx + 5], Nodes::Scalar::PLAIN)
          idx += 6
        end

        true
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
        if @string.getbyte(pos) == 0x3F # ?
          try do
            match("?") &&
              peek_ahead { eos? || parse_s_white || parse_b_break } &&
              parse_s_separate(n, c) && parse_ns_flow_map_explicit_entry(n, c)
          end || parse_ns_flow_map_implicit_entry(n, c)
        else
          parse_ns_flow_map_implicit_entry(n, c)
        end
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
        case @string.getbyte(pos)
        when 0x3A # : — must be empty key entry
          parse_c_ns_flow_map_empty_key_entry(n, c)
        when 0x5B, 0x7B, 0x27, 0x22 # [ { ' " — must be JSON key
          parse_c_ns_flow_map_json_key_entry(n, c)
        else # plain scalar, *, !, & — YAML key (: and JSON starts already dispatched)
          parse_ns_flow_map_yaml_key_entry(n, c)
        end
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
          events_cache_discard
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
            !peek_ahead { parse_ns_plain_safe(c) } &&
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
        emit_mapping_start(pos, Nodes::Mapping::FLOW)

        matched =
          if @string.getbyte(pos) == 0x3F # ?
            try do
              match("?") &&
                peek_ahead { eos? || parse_s_white || parse_b_break } &&
                parse_s_separate(n, c) &&
                parse_ns_flow_map_explicit_entry(n, c)
            end || parse_ns_flow_pair_entry(n, c)
          else
            parse_ns_flow_pair_entry(n, c)
          end

        if matched
          events_cache_flush
          emit_mapping_end(pos)
          true
        else
          events_cache_discard
          false
        end
      end

      # [151]
      # ns-flow-pair-entry(n,c) ::=
      #   ns-flow-pair-yaml-key-entry(n,c)
      #   | c-ns-flow-map-empty-key-entry(n,c)
      #   | c-ns-flow-pair-json-key-entry(n,c)
      def parse_ns_flow_pair_entry(n, c)
        case @string.getbyte(pos)
        when 0x3A # : — empty key
          parse_c_ns_flow_map_empty_key_entry(n, c)
        when 0x5B, 0x7B, 0x27, 0x22 # [ { ' " — JSON key
          parse_c_ns_flow_pair_json_key_entry(n, c)
        else
          parse_ns_flow_pair_yaml_key_entry(n, c)
        end
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
        pos_start = pos
        try do
          if parse_ns_flow_yaml_node(nil, c)
            parse_s_separate_in_line
            (pos - pos_start) <= 1024
          end
        end
      end

      # [155]
      # c-s-implicit-json-key(c) ::=
      #   c-flow-json-node(n/a,c)
      #   s-separate-in-line?
      #   <at_most_1024_characters_altogether>
      def parse_c_s_implicit_json_key(c)
        pos_start = pos
        try do
          if parse_c_flow_json_node(nil, c)
            parse_s_separate_in_line
            (pos - pos_start) <= 1024
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
        pos_start = pos
        result =
          case c
          when :block_key then parse_ns_plain_one_line(c)
          when :flow_in then parse_ns_plain_multi_line(n, c)
          when :flow_key then parse_ns_plain_one_line(c)
          when :flow_out then parse_ns_plain_multi_line(n, c)
          else raise InternalException, c.inspect
          end

        if result
          source = from(pos_start)

          if source.include?("\n")
            value = source.dup
            value.gsub!(/[ \t]*(?:\r?\n[ \t]*)+/) { |m| (nl = m.count("\n")) == 1 ? " " : "\n" * (nl - 1) }
          else
            value = source
          end

          emit_scalar(pos_start, pos, value, source, Nodes::Scalar::PLAIN)
        end

        result
      end

      # [157]
      # c-flow-json-content(n,c) ::=
      #   c-flow-sequence(n,c) | c-flow-mapping(n,c)
      #   | c-single-quoted(n,c) | c-double-quoted(n,c)
      def parse_c_flow_json_content(n, c)
        case @string.getbyte(pos)
        when 0x5B then parse_c_flow_sequence(n, c)  # [
        when 0x7B then parse_c_flow_mapping(n, c)   # {
        when 0x27 then parse_c_single_quoted(n, c)  # '
        when 0x22 then parse_c_double_quoted(n, c)  # "
        end
      end

      # [158]
      # ns-flow-content(n,c) ::=
      #   ns-flow-yaml-content(n,c) | c-flow-json-content(n,c)
      def parse_ns_flow_content(n, c)
        case @string.getbyte(pos)
        when 0x5B then parse_c_flow_sequence(n, c)  # [
        when 0x7B then parse_c_flow_mapping(n, c)   # {
        when 0x27 then parse_c_single_quoted(n, c)  # '
        when 0x22 then parse_c_double_quoted(n, c)  # "
        else parse_ns_flow_yaml_content(n, c)
        end
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
        case @string.getbyte(pos)
        when 0x2A # * — alias
          parse_c_ns_alias_node
        when 0x21, 0x26 # ! & — properties, then content or empty
          try do
            parse_c_ns_properties(n, c) &&
              (try { parse_s_separate(n, c) && parse_ns_flow_content(n, c) } || parse_e_scalar)
          end
        else
          parse_ns_flow_yaml_content(n, c)
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
        case @string.getbyte(pos)
        when 0x2A # * — alias
          parse_c_ns_alias_node
        when 0x21, 0x26 # ! & — properties first, then optional content
          try do
            parse_c_ns_properties(n, c) &&
              (try { parse_s_separate(n, c) && parse_ns_flow_content(n, c) } || parse_e_scalar)
          end
        else
          parse_ns_flow_content(n, c)
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
                  peek_ahead { eos? || parse_s_white || parse_b_break }
              end ||
              try do
                (t = parse_c_chomping_indicator) &&
                  (m = parse_c_indentation_indicator(n)) &&
                  peek_ahead { eos? || parse_s_white || parse_b_break }
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
        pos_start = pos

        if match(/[\u{31}-\u{39}]/)
          Integer(from(pos_start))
        else
          check(/.*\n((?:\ *\n)*)(\ *)(.?)/)

          pre = self[1]
          if !self[3].empty?
            m = self[2].length - n
          else
            # Find the max leading-space count across blank lines in pre
            # without constructing dynamic regexes.
            max_spaces = 0
            line_spaces = 0
            pidx = 0
            plen = pre.bytesize
            while pidx < plen
              if pre.getbyte(pidx) == 0x0A
                max_spaces = line_spaces if line_spaces > max_spaces
                line_spaces = 0
              else
                line_spaces += 1
              end
              pidx += 1
            end
            m = max_spaces - n
          end

          if m > 0
            # Check if any blank line in pre has more than m+n spaces
            check_len = m + n
            pidx = 0
            plen = pre.bytesize
            while pidx < plen
              line_spaces = 0
              while pidx < plen && pre.getbyte(pidx) != 0x0A
                line_spaces += 1
                pidx += 1
              end
              pidx += 1 # skip newline
              raise_syntax_error("Invalid indentation indicator") if line_spaces > check_len
            end
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
        when :clip then parse_b_as_line_feed || eos?
        when :keep then parse_b_as_line_feed || eos?
        when :strip then parse_b_non_content || eos?
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
        pos_start = pos

        if try {
          match("|") &&
          (m, t = parse_c_b_block_header(n)) &&
          parse_l_literal_content(n + m, t)
        } then
          @in_scalar = false
          value = events_cache_pop.map { |line| "#{line}\n" }.join

          case t
          when :clip
            value.sub!(/\n+\z/, "\n")
          when :strip
            value.sub!(/\n+\z/, "")
          when :keep
            # nothing
          else
            raise InternalException, t.inspect
          end

          trimmed_end = @source.trim_comments(pos)
          source_str = @string.byteslice(pos_start...trimmed_end).chomp
          emit_scalar(pos_start, trimmed_end, value, source_str, Nodes::Scalar::LITERAL)
          true
        else
          @in_scalar = false
          events_cache_discard
          false
        end
      end

      # [171]
      # l-nb-literal-text(n) ::=
      #   l-empty(n,block-in)*
      #   s-indent(n) nb-char+
      def parse_l_nb_literal_text(n)
        events_cache_size = @events_cache.size

        try do
          if star { parse_l_empty(n, :block_in) } && parse_s_indent(n)
            pos_start = pos

            if match(/[\t\x20-\x7E\u0085\u00A0-\uD7FF\uE000-\uFEFE\uFF00-\uFFFD\u{10000}-\u{10FFFF}]+/)
              events_push(from(pos_start))
              true
            end
          else
            # When parsing all of the l_empty calls, we may have added a bunch
            # of empty lines to the events cache. We need to clear those out
            # here.
            @events_cache.pop while @events_cache.size > events_cache_size
            false
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
        pos_start = pos

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

          trimmed_end = @source.trim_comments(pos)
          source_str = @string.byteslice(pos_start...trimmed_end).chomp
          emit_scalar(pos_start, trimmed_end, value, source_str, Nodes::Scalar::FOLDED)
          true
        else
          @in_scalar = false
          events_cache_discard
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
            pos_start = pos
            match(/[\t\x20-\x7E\u0085\u00A0-\uD7FF\uE000-\uFEFE\uFF00-\uFFFD\u{10000}-\u{10FFFF}]*/)
            events_push("#{@text_prefix}#{from(pos_start)}")
            true
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
            pos_start = pos
            match(/[\t\x20-\x7E\u0085\u00A0-\uD7FF\uE000-\uFEFE\uFF00-\uFFFD\u{10000}-\u{10FFFF}]*/)
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

        @context.within_block_sequence(pos, n) do
          indent = n + m

          # Cache the sequence start + first entry speculatively.
          events_cache_push
          emit_sequence_start(pos, Nodes::Sequence::BLOCK)

          if try { parse_s_indent(indent) && (parse_fast_seq_entry(indent) || parse_c_l_block_seq_entry(indent)) }
            # First entry succeeded — flush and continue without outer cache.
            events_cache_flush

            indent_str = INDENT_STRINGS[indent]
            while true
              pos_before = pos

              if (@check_forbidden && @forbidden_content[pos_before]) || !skip(indent_str)
                break
              elsif !parse_fast_seq_entry(indent) && !parse_c_l_block_seq_entry(indent)
                self.pos = pos_before
                break
              end
            end

            emit_sequence_end(pos)
            true
          else
            @anchor, @tag = events_cache_pop_first_properties
            false
          end
        end
      end

      # Regex for the fast path of block sequence entries. Matches:
      #   "- " plain_value "\n"
      # where the value is a simple plain scalar on a single line.
      # Group 1 = value.
      # Parse a block sequence entry using the fast path when possible to avoid
      # going through the whole recursive descent parser.
      def parse_fast_seq_entry(n)
        # Only attempt when there are no pending properties and we're not in
        # a bare document with forbidden content at this position.
        return false if @anchor || @tag
        return false if @check_forbidden && @forbidden_content[pos]

        pos_start = pos
        return false unless skip(/-[ \t]+/)

        value_start = pos
        if !(value_len = skip(/(?:[^\s,\[\]{}#&*!|>'"%@`\uFEFF?:-]|[?:-](?=[^\s\uFEFF]))(?:[ \t]*(?:[^ \t\r\n:#\uFEFF]|:(?=[^ \t\r\n\uFEFF])|(?<=[^ \t\r\n])\#))*/))
          self.pos = pos_start
          return false
        end

        value_end = pos
        unless skip(/[ \t]*\n/)
          self.pos = pos_start
          return false
        end

        # Check that the next line is not a continuation (indented deeper
        # than the current sequence level) or a nested structure.
        next_pos = pos
        if next_pos < @string.bytesize
          next_indent = 0
          next_indent += 1 while @string.getbyte(next_pos + next_indent) == 0x20
          next_byte = @string.getbyte(next_pos + next_indent)

          if next_indent > n && next_byte != nil && next_byte != 0x0A
            self.pos = pos_start
            return false
          end
        end

        emit_fast_scalar(value_start, value_end)

        nb = @string.getbyte(pos)
        star { parse_l_comment } if nb == 0x0A || nb == 0x20 || nb == 0x09 || nb == 0x23 # \n, space, tab, #
        true
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
        return false unless @string.getbyte(pos) == 0x2D # -
        try do
          match("-") &&
            !peek_ahead { parse_ns_char } &&
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
            if @string.getbyte(pos) == 0x2D # -
              parse_ns_l_compact_sequence(n + 1 + m) || parse_ns_l_compact_mapping(n + 1 + m)
            else
              parse_ns_l_compact_mapping(n + 1 + m)
            end
        end || parse_s_l_block_node(n, c) || try { parse_e_node && parse_s_l_comments }
      end

      # [186]
      # ns-l-compact-sequence(n) ::=
      #   c-l-block-seq-entry(n)
      #   ( s-indent(n) c-l-block-seq-entry(n) )*
      def parse_ns_l_compact_sequence(n)
        return false unless @string.getbyte(pos) == 0x2D # '-'

        # Cache the sequence start + first entry speculatively.
        events_cache_push
        emit_sequence_start(pos, Nodes::Sequence::BLOCK)

        if try { parse_c_l_block_seq_entry(n) }
          # First entry succeeded — flush and continue without outer cache.
          events_cache_flush
          star { try { parse_s_indent(n) && parse_c_l_block_seq_entry(n) } }
          emit_sequence_end(pos)
          true
        else
          events_cache_discard
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

        @context.within_block_mapping(pos, n) do
          indent = n + m

          # Cache the mapping start + first entry speculatively. If the first
          # entry fails, we discard everything.
          events_cache_push
          emit_mapping_start(pos, Nodes::Mapping::BLOCK)

          if try { parse_s_indent(indent) && (parse_fast_mapping_entry(indent) || parse_ns_l_block_map_entry(indent)) }
            # First entry succeeded — the mapping is committed. Flush the
            # cached mapping start + first entry events, then parse remaining
            # entries without the outer cache so events emit directly.
            events_cache_flush

            # Inlined star { try { parse_s_indent && (fast || slow) } }
            # to avoid block allocation overhead in the hot loop.
            indent_str = INDENT_STRINGS[indent]

            while true
              pos_before = pos

              if (@check_forbidden && @forbidden_content[pos_before]) || !skip(indent_str)
                break
              elsif !parse_fast_mapping_entry(indent) && !parse_ns_l_block_map_entry(indent)
                self.pos = pos_before
                break
              end
            end

            emit_mapping_end(pos)
            true
          else
            events_cache_discard
            false
          end
        end
      end

      # Plain scalar for block context fast path (no capture groups).
      # Parse a block mapping entry using the fast path when possible to avoid
      # going through the whole recursive descent parser.
      def parse_fast_mapping_entry(n)
        # Only attempt when there are no pending properties and we're not in
        # a bare document with forbidden content at this position.
        return false if @anchor || @tag
        return false if @check_forbidden && @forbidden_content[pos]

        # Match key, separator, value, and trailing whitespace+newline
        # using separate regexes to avoid capture group allocations.
        pos_start = pos
        key_len = skip(/(?:[^\s,\[\]{}#&*!|>'"%@`\uFEFF?:-]|[?:-](?=[^\s\uFEFF]))(?:[ \t]*(?:[^ \t\r\n:#\uFEFF]|:(?=[^ \t\r\n\uFEFF])|(?<=[^ \t\r\n])\#))*/)
        return false unless key_len

        unless skip(/:[ \t]+/)
          self.pos = pos_start
          return false
        end

        value_start = pos
        if !(value_len = skip(/(?:[^\s,\[\]{}#&*!|>'"%@`\uFEFF?:-]|[?:-](?=[^\s\uFEFF]))(?:[ \t]*(?:[^ \t\r\n:#\uFEFF]|:(?=[^ \t\r\n\uFEFF])|(?<=[^ \t\r\n])\#))*/))
          self.pos = pos_start
          return false
        end

        value_end = pos
        unless skip(/[ \t]*\n/)
          self.pos = pos_start
          return false
        end

        # Check that the next line is not a continuation (indented deeper
        # than the current mapping level) or a block scalar/sequence.
        next_pos = pos
        if next_pos < @string.bytesize
          next_indent = 0
          next_indent += 1 while @string.getbyte(next_pos + next_indent) == 0x20
          next_byte = @string.getbyte(next_pos + next_indent)

          if next_indent > n && next_byte != nil && next_byte != 0x0A
            self.pos = pos_start
            return false
          end
        end

        emit_fast_scalar(pos_start, pos_start + key_len)
        emit_fast_scalar(value_start, value_end)

        # Consume trailing blank/comment lines that the normal parser would
        # handle via parse_s_l_comments in the value's block node path.
        # Quick check: if the next byte can't start a comment or blank line,
        # skip the loop entirely.
        nb = @string.getbyte(pos)
        star { parse_l_comment } if nb == 0x0A || nb == 0x20 || nb == 0x09 || nb == 0x23 # \n, space, tab, #
        true
      end

      # [188]
      # ns-l-block-map-entry(n) ::=
      #   c-l-block-map-explicit-entry(n)
      #   | ns-l-block-map-implicit-entry(n)
      def parse_ns_l_block_map_entry(n)
        (@string.getbyte(pos) == 0x3F && parse_c_l_block_map_explicit_entry(n)) || # '?'
          parse_ns_l_block_map_implicit_entry(n)
      end

      # [189]
      # c-l-block-map-explicit-entry(n) ::=
      #   c-l-block-map-explicit-key(n)
      #   ( l-block-map-explicit-value(n)
      #   | e-node )
      def parse_c_l_block_map_explicit_entry(n)
        events_cache_push

        unless try { parse_c_l_block_map_explicit_key(n) }
          events_cache_discard
          return false
        end

        # Key succeeded — flush so the value is parsed at a lower depth.
        events_cache_flush
        parse_l_block_map_explicit_value(n) || parse_e_node
      end

      # [190]
      # c-l-block-map-explicit-key(n) ::=
      #   '?'
      #   s-l+block-indented(n,block-out)
      def parse_c_l_block_map_explicit_key(n)
        try do
          match("?") &&
            peek_ahead { eos? || parse_s_white || parse_b_break } &&
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
        pos_start = pos

        # The key is speculative — cache it in case the entry fails
        # (e.g., ':' is not found after the key).
        events_cache_push

        unless (parse_ns_s_block_map_implicit_key || parse_e_node) &&
               @string.getbyte(pos) == 0x3A # :
          events_cache_discard
          self.pos = pos_start
          return false
        end

        # Key parsed and ':' confirmed — the entry is committed. Flush
        # the key events so the value is parsed at a lower cache depth,
        # enabling direct emission in nested fast paths.
        events_cache_flush
        parse_c_l_block_map_implicit_value(n)
      end

      # [193]
      # ns-s-block-map-implicit-key ::=
      #   c-s-implicit-json-key(block-key)
      #   | ns-s-implicit-yaml-key(block-key)
      def parse_ns_s_block_map_implicit_key
        case @string.getbyte(pos)
        when 0x5B, 0x7B, 0x27, 0x22 # [ { ' " — must be JSON key
          parse_c_s_implicit_json_key(:block_key)
        when 0x21, 0x26 # ! & — could be either (properties before JSON or YAML content)
          parse_c_s_implicit_json_key(:block_key) ||
            parse_ns_s_implicit_yaml_key(:block_key)
        else
          parse_ns_s_implicit_yaml_key(:block_key)
        end
      end

      # [194]
      # c-l-block-map-implicit-value(n) ::=
      #   ':' (
      #   s-l+block-node(n,block-out)
      #   | ( e-node s-l-comments ) )
      def parse_c_l_block_map_implicit_value(n)
        return false unless @string.getbyte(pos) == 0x3A # :
        try do
          skip(":") &&
            (parse_s_l_block_node(n, :block_out) || try { parse_e_node && parse_s_l_comments })
        end
      end

      # [195]
      # ns-l-compact-mapping(n) ::=
      #   ns-l-block-map-entry(n)
      #   ( s-indent(n) ns-l-block-map-entry(n) )*
      def parse_ns_l_compact_mapping(n)
        # Cache the mapping start + first entry speculatively.
        events_cache_push
        emit_mapping_start(pos, Nodes::Mapping::BLOCK)

        if try { parse_fast_mapping_entry(n) || parse_ns_l_block_map_entry(n) }
          # First entry succeeded — flush and continue without outer cache.
          events_cache_flush
          star { try { parse_s_indent(n) && (parse_fast_mapping_entry(n) || parse_ns_l_block_map_entry(n)) } }
          emit_mapping_end(pos)
          true
        else
          events_cache_discard
          false
        end
      end

      # [196]
      # s-l+block-node(n,c) ::=
      #   s-l+block-in-block(n,c) | s-l+flow-in-block(n)
      def parse_s_l_block_node(n, c)
        parse_s_l_block_scalar(n, c) || parse_s_l_block_collection(n, c) || parse_s_l_flow_in_block(n)
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

      # [199]
      # s-l+block-scalar(n,c) ::=
      #   s-separate(n+1,c)
      #   ( c-ns-properties(n+1,c) s-separate(n+1,c) )?
      #   ( c-l+literal(n) | c-l+folded(n) )
      def parse_s_l_block_scalar(n, c)
        try do
          if parse_s_separate(n + 1, c)
            try { parse_c_ns_properties(n + 1, c) && parse_s_separate(n + 1, c) }
            case @string.getbyte(pos)
            when 0x7C then parse_c_l_literal(n)  # |
            when 0x3E then parse_c_l_folded(n)   # >
            end
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
          skip("\u{FEFF}")
          star { parse_l_comment }
        end
      end

      # [203]
      # c-directives-end ::=
      #   '-' '-' '-'
      def parse_c_directives_end
        if try { match("---") && peek_ahead { eos? || parse_s_white || parse_b_break } }
          document_end_event_flush
          @doc_start_implicit = false
          true
        end
      end

      # [204]
      # c-document-end ::=
      #   '.' '.' '.'
      def parse_c_document_end
        if match("...")
          @doc_end_implicit = false if @doc_end_pos
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
        previous_check = @check_forbidden
        @in_bare_document = true
        @check_forbidden = @has_forbidden_content

        result =
          try do
            !try { start_of_line? && (parse_c_directives_end || parse_c_document_end) && (match(/[\u{0A}\u{0D}]/) || parse_s_white || eos?) } &&
              parse_s_l_block_node(-1, :block_in)
          end

        @in_bare_document = previous
        @check_forbidden = previous_check
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
        case @string.getbyte(pos)
        when 0x25 # % — directive document
          try { plus { parse_l_directive } && parse_l_explicit_document } ||
            parse_l_explicit_document ||
            parse_l_bare_document
        when 0x2D # - — could be explicit document (---) or bare document
          parse_l_explicit_document ||
            parse_l_bare_document
        else
          parse_l_bare_document
        end
      end

      # [211]
      # l-yaml-stream ::=
      #   l-document-prefix* l-any-document?
      #   ( ( l-document-suffix+ l-document-prefix*
      #   l-any-document? )
      #   | ( l-document-prefix* l-explicit-document? ) )*
      def parse_l_yaml_stream
        emit_stream_start(pos)

        star { parse_l_document_prefix }
        reset_document_state
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

        raise_syntax_error("Parser finished before end of input") unless eos?
        document_end_event_flush
        emit_stream_end(pos)
        true
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
        attr_reader :value, :psych_node

        def initialize(value, psych_node)
          @value = value
          @psych_node = psych_node
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
        attr_accessor :anchor, :tag, :dirty

        def accept(visitor)
          visitor.visit_array(self)
        end
      end

      # Represents a hash of nodes.
      class HashNode < Node
        attr_accessor :anchor, :tag

        def accept(visitor)
          visitor.visit_hash(self)
        end
      end

      # Represents the nil value.
      class NilNode < Node
        def accept(visitor)
          raise "Visiting NilNode is not supported"
        end
      end

      # Represents a generic object that is not matched by any of the other node
      # types.
      class ObjectNode < Node
        # The explicit tag associated with the object.
        attr_accessor :tag

        # Whether or not this object was modified after being loaded. In this
        # case we cannot rely on the source formatting, and need to instead
        # format the value ourselves.
        attr_accessor :dirty

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
        # The explicit tag associated with the object.
        attr_accessor :tag

        # Whether or not this object was modified after being loaded. In this
        # case we cannot rely on the source formatting, and need to instead
        # format the value ourselves.
        attr_accessor :dirty

        def accept(visitor)
          visitor.visit_string(self)
        end
      end

      # The visitor is responsible for walking the tree and generating the YAML
      # output.
      class Visitor
        def initialize(q, sequence_indent: false)
          @q = q
          @sequence_indent = sequence_indent
        end

        # Visit an AliasNode.
        def visit_alias(node)
          with_comments(node) { |value| @q.text("*#{value}") }
        end

        # Visit an ArrayNode.
        def visit_array(node)
          with_comments(node) do |value|
            if value.empty? || ((psych_node = node.psych_node).is_a?(Nodes::Sequence) && psych_node.style == Nodes::Sequence::FLOW && psych_node.children.any?)
              visit_array_contents_flow(node.anchor, node.tag, value)
            else
              visit_array_contents_block(node.anchor, node.tag, node.dirty, value)
            end
          end
        end

        # Visit a HashNode.
        def visit_hash(node)
          with_comments(node) do |value|
            if value.empty? || ((psych_node = node.psych_node).is_a?(Nodes::Mapping) && psych_node.style == Nodes::Mapping::FLOW)
              visit_hash_contents_flow(node.anchor, node.tag, value)
            else
              visit_hash_contents_block(node.anchor, node.tag, value)
            end
          end
        end

        # Visit an ObjectNode.
        def visit_object(node)
          with_comments(node) do |value|
            if !node.dirty && (psych_node = node.psych_node)
              if (tag = node.tag)
                @q.text("#{tag} ")
              end

              @q.text(psych_node.source || psych_node.value)
            else
              if (tag = node.tag) && tag != "tag:yaml.org,2002:binary"
                @q.text("#{tag} ")
              end

              @q.text(dump_object(value))
            end
          end
        end

        # Visit an OmapNode.
        def visit_omap(node)
          with_comments(node) do |value|
            visit_array_contents_block(node.anchor, "!!omap", false, value)
          end
        end

        # Visit a SetNode.
        def visit_set(node)
          with_comments(node) do |value|
            visit_hash_contents_block(node.anchor, "!set", value)
          end
        end

        # Visit a StringNode.
        def visit_string(node)
          with_comments(node) do |value|
            if !node.dirty && (psych_node = node.psych_node)
              if (tag = node.tag)
                @q.text("#{tag} ")
              end

              @q.text(psych_node.source || psych_node.value)
            else
              if (tag = node.tag) && tag != "tag:yaml.org,2002:binary"
                @q.text("#{tag} ")
              end

              @q.text(dump_object(value))
            end
          end
        end

        private

        # TODO: Certain objects require special formatting. Usually this
        # involves scanning the object itself and determining what kind of YAML
        # object it is, then dumping it back out. We rely on Psych itself to do
        # this formatting for us.
        #
        # Note this is the one place where we indirectly rely on libyaml,
        # because Psych delegates to libyaml to dump the object. This is less
        # than ideal, because it means in some circumstances we have an indirect
        # dependency. Ideally this would all be removed in favor of our own
        # formatting.
        def dump_object(value)
          Psych.dump(value, indentation: @q.indent)[/\A--- (.+?)(?:\n\.\.\.)?\n\z/m, 1]
        end

        # Shortcut to visit a node by passing this visitor to the accept method.
        def visit(node)
          node.accept(self)
        end

        # Visit the elements within an array in the block format.
        def visit_array_contents_block(anchor, tag, dirty, contents)
          @q.group do
            if anchor
              @q.text("&#{anchor}")
              tag ? @q.text(" ") : @q.breakable
            end

            if tag
              @q.text(tag)
              @q.breakable
            end

            current_line = nil
            contents.each_with_index do |element, index|
              psych_node = element.psych_node
              leading = psych_node&.comments&.leading

              if index > 0
                @q.breakable

                if !dirty && current_line && psych_node
                  start_line = (leading&.first || psych_node).start_line
                  @q.breakable if start_line - current_line >= 2
                end
              end

              current_line = psych_node&.end_line
              visit_leading_comments(leading) if leading&.any?

              if psych_node && (trailing = psych_node.comments.trailing).any?
                current_line = trailing.last.end_line
              end

              @q.text("-")
              next if element.is_a?(NilNode)

              @q.text(" ")
              @q.nest(2) do
                if psych_node
                  psych_node.comments.without_leading { visit(element) }
                else
                  visit(element)
                end
              end
            end

            @q.current_group.break
          end
        end

        # Visit the elements within an array in the flow format.
        def visit_array_contents_flow(anchor, tag, contents)
          @q.group do
            @q.text("&#{anchor} ") if anchor
            @q.text("#{tag} ") if tag
            @q.text("[")

            unless contents.empty?
              @q.nest(2) do
                @q.breakable("")
                @q.seplist(contents, -> { @q.comma_breakable }) { |element| visit(element) }
              end
              @q.breakable("")
            end

            @q.text("]")
          end
        end

        # Visit a key value pair within a hash.
        def visit_hash_key_value(key, value)
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
          else
            raise InternalException
          end

          @q.text(":")

          case value
          when NilNode
            # skip
          when OmapNode, SetNode
            @q.text(" ")
            @q.nest(2) { visit(value) }
          when ArrayNode
            if ((psych_node = value.psych_node).is_a?(Nodes::Sequence) && psych_node.style == Nodes::Sequence::FLOW && psych_node.children.any?) || value.value.empty?
              @q.text(" ")
              visit(value)
            elsif inlined || value.anchor || value.tag || value.value.empty?
              @q.text(" ")
              @q.nest(2) { visit(value) }
            elsif @sequence_indent
              @q.nest(2) do
                @q.breakable
                visit(value)
              end
            else
              @q.breakable
              visit(value)
            end
          when HashNode
            if ((psych_node = value.psych_node).is_a?(Nodes::Mapping) && psych_node.style == Nodes::Mapping::FLOW) || value.value.empty?
              @q.text(" ")
              visit(value)
            elsif inlined || value.anchor || value.tag
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
          else
            raise InternalException
          end
        end

        # Visit the key/value pairs within a hash in the block format.
        def visit_hash_contents_block(anchor, tag, children)
          @q.group do
            if anchor
              @q.text("&#{anchor}")
              tag ? @q.text(" ") : @q.breakable
            end

            if tag
              @q.text(tag)
              @q.breakable
            end

            current_line = nil
            ((0...children.length) % 2).each do |index|
              key = children[index]
              value = children[index + 1]

              if index > 0
                @q.breakable

                if current_line && (psych_node = key.psych_node)
                  start_line = psych_node.start_line
                  if (leading = key.psych_node.comments.leading).any?
                    start_line = leading.first.start_line
                  end

                  @q.breakable if start_line - current_line >= 2
                end
              end

              current_line = (psych_node = value.psych_node) ? psych_node.end_line : nil
              visit_hash_key_value(key, value)
            end

            @q.current_group.break
          end
        end

        # Visit the key/value pairs within a hash in the flow format.
        def visit_hash_contents_flow(anchor, tag, children)
          @q.group do
            @q.text("&#{anchor} ") if anchor
            @q.text("#{tag} ") if tag
            @q.text("{")

            unless children.empty?
              @q.nest(2) do
                @q.breakable

                ((0...children.length) % 2).each do |index|
                  @q.comma_breakable if index != 0
                  visit_hash_key_value(children[index], children[index + 1])
                end
              end
              @q.breakable
            end

            @q.text("}")
          end
        end

        # Visit the leading comments for a node, printing them out with proper
        # line breaks.
        def visit_leading_comments(comments)
          line = nil

          comments.each do |comment|
            while line && line < comment.start_line
              @q.breakable
              line += 1
            end

            @q.text(comment.value)
            line = comment.end_line
          end

          @q.breakable
        end

        # Print out the leading and trailing comments of a node, as well as
        # yielding the value of the node to the block.
        def with_comments(node)
          if (comments = node.psych_node&.comments) && (leading = comments.leading).any?
            visit_leading_comments(leading)
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
      def emit(object)
        if @started
          @io << "...\n"
        else
          @started = true
        end

        # Very rare circumstance here that there are leading comments attached
        # to the root object of a document that occur before the --- marker. In
        # this case we want to output them first here, then dump the object.
        reload_comments = nil
        if (object.is_a?(LoadedObject) || object.is_a?(LoadedHash)) && (psych_node = object.psych_node).comments? && (leading = psych_node.comments.leading).any?
          leading = [*leading]
          line = psych_node.start_line - 1

          while leading.any? && leading.last.start_line == line
            leading.pop
            line -= 1
          end

          psych_node.comments.leading.slice!(0, leading.length)
          line = nil

          leading.each do |comment|
            if line && (line < comment.start_line)
              @io << "\n" * (comment.start_line - line - 1)
            end

            @io << comment.value
            @io << "\n"

            line = comment.start_line
          end

          reload_comments = leading.concat(psych_node.comments.leading)
        end

        @io << "---"

        if (node = dump(object)).is_a?(NilNode)
          @io << "\n"
        else
          q = Formatter.new(+"", 79, "\n") { |n| " " * n }

          if (node.is_a?(ArrayNode) || node.is_a?(HashNode)) && !node.value.empty?
            q.breakable
          else
            q.text(" ")
          end

          node.accept(Visitor.new(q, sequence_indent: @options.fetch(:sequence_indent, false)))
          q.breakable
          q.current_group.break
          q.flush

          @io << q.output
        end

        # If we initially split up the leading comments, then we need to reload
        # them back to their original state here.
        unless reload_comments.nil?
          object.psych_node.comments.leading.replace(reload_comments)
        end
      end

      private

      # Dump the tag value for a given node.
      def dump_tag(value)
        case value
        when /\Atag:yaml.org,2002:(.+)\z/
          "!!#{$1}"
        else
          value
        end
      end

      # Walk through the given object and convert it into a tree of nodes.
      def dump(base_object)
        if base_object.nil?
          NilNode.new(nil, nil)
        else
          object = base_object
          psych_node = nil
          dirty = false

          if base_object.is_a?(LoadedObject)
            object = base_object.__getobj__
            psych_node = base_object.psych_node
            dirty = base_object.dirty
          elsif base_object.is_a?(LoadedHash)
            object = base_object.__getobj__
            psych_node = base_object.psych_node
          end

          if @object_nodes.key?(object)
            @object_anchors[object] ||=
              if psych_node.is_a?(Nodes::Alias)
                psych_node.anchor
              else
                @object_anchor += 1
              end

            AliasNode.new(@object_nodes[object].anchor = @object_anchors[object], psych_node)
          else
            case object
            when Psych::Omap
              @object_nodes[object] = OmapNode.new(object.map { |(key, value)| HashNode.new([dump(key), dump(value)], nil) }, psych_node)
            when Psych::Set
              @object_nodes[object] = SetNode.new(object.flat_map { |key, value| [dump(key), dump(value)] }, psych_node)
            when Array
              dumped = ArrayNode.new(object.map { |element| dump(element) }, psych_node)
              dumped.tag = dump_tag(psych_node&.tag)
              dumped.dirty = true if dirty

              @object_nodes[object] = dumped
            when Hash
              contents =
                if base_object.is_a?(LoadedHash)
                  base_object.psych_assocs.flat_map { |(key, value)| [dump(key), dump(value)] }
                else
                  object.flat_map { |key, value| [dump(key), dump(value)] }
                end

              dumped = HashNode.new(contents, psych_node)
              dumped.tag = dump_tag(psych_node&.tag)

              @object_nodes[object] = dumped
            when String
              dumped = StringNode.new(object, psych_node)
              dumped.tag = dump_tag(psych_node&.tag)
              dumped.dirty = dirty
              dumped
            else
              dumped = ObjectNode.new(object, psych_node)
              dumped.tag = dump_tag(psych_node&.tag)
              dumped.dirty = dirty
              dumped
            end
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
      def dump(base_object)
        object = base_object

        if base_object.is_a?(LoadedObject) || base_object.is_a?(LoadedHash)
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

    def self.unsafe_load(yaml, filename: nil, fallback: false, symbolize_names: false, freeze: false, strict_integer: false, parse_symbols: true, comments: false)
      result = parse(yaml, filename: filename, comments: comments)
      return fallback unless result

      result.to_ruby(symbolize_names: symbolize_names, freeze: freeze, strict_integer: strict_integer, parse_symbols: parse_symbols, comments: comments)
    end

    def self.safe_load(yaml, permitted_classes: [], permitted_symbols: [], aliases: false, filename: nil, fallback: nil, symbolize_names: false, freeze: false, strict_integer: false, parse_symbols: true, comments: false)
      result = parse(yaml, filename: filename, comments: comments)
      return fallback unless result

      class_loader = ClassLoader::Restricted.new(permitted_classes.map(&:to_s), permitted_symbols.map(&:to_s))
      scanner = ScalarScanner.new(class_loader, strict_integer: strict_integer, parse_symbols: parse_symbols)
      visitor =
        if aliases
          Visitors::ToRuby.new(scanner, class_loader, symbolize_names: symbolize_names, freeze: freeze, comments: comments)
        else
          Visitors::NoAliasRuby.new(scanner, class_loader, symbolize_names: symbolize_names, freeze: freeze, comments: comments)
        end

      visitor.accept(result)
    end

    def self.load(yaml, permitted_classes: [Symbol], permitted_symbols: [], aliases: false, filename: nil, fallback: nil, symbolize_names: false, freeze: false, strict_integer: false, parse_symbols: true, comments: false)
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
        parse_symbols: parse_symbols,
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

    def self.safe_load_stream(yaml, filename: nil, permitted_classes: [], aliases: false, comments: false)
      documents = parse_stream(yaml, filename: filename).children.map do |child|
        stream = Psych::Nodes::Stream.new
        stream.children << child
        safe_load(stream.to_yaml, permitted_classes: permitted_classes, aliases: aliases, comments: comments)
      end

      if block_given?
        documents.each { |doc| yield doc }
        nil
      else
        documents
      end
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
      emitter.emit(o)
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
      emitter.emit(o)
      io || real_io.string
    end

    # Dump a stream of objects to a YAML string.
    def self.dump_stream(*objects)
      real_io = io || StringIO.new
      emitter = Emitter.new(real_io, {})
      objects.each { |object| emitter.emit(object) }
      io || real_io.string
    end
  end
end
