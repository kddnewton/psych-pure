# Psych::Pure

[![Build Status](https://github.com/kddnewton/psych-pure/workflows/Main/badge.svg)](https://github.com/kddnewton/psych-pure/actions)
[![Gem Version](https://img.shields.io/gem/v/psych-pure.svg)](https://rubygems.org/gems/psych-pure)

`Psych::Pure` is a YAML library written in Ruby. It functions as an extension of `Psych`, the main CRuby YAML library. The circumstances under which you may choose this library are:

* You have some issue installing `libyaml` and/or you want to avoid a native dependency.
* You have a need to parse comments from YAML source and/or to write comments out to YAML source.
* You need to parse exactly according to the YAML 1.2 spec.

Note that this library comes with a couple of caveats:

* It will only parse YAML 1.2. Other previous versions are unsupported.
* It will only parse UTF-8 strings. Other unicode encodings are unsupported.
* The parser is significantly slower and less efficient than `Psych::Parser`.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "psych-pure"
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install psych-pure

## Usage

`Psych::Pure` largely mirrors the various `Psych` APIs. The main entrypoints are:

* `Psych::Pure.parse(source)` - parses a YAML string into a YAML syntax tree
* `Psych::Pure.load(source)` - loads a YAML string into a Ruby object
* `Psych::Pure.dump(object)` - dumps a Ruby object to a YAML string

All of the various `parse` APIs come with the additional `comments:` keyword option. This option tells the parser to parse out comments and attach them to the resulting tree. Nodes in the tree are then responsible for maintaining their own leading and trailing comments.

All of the various `load` APIs also come with the additional `comments:` keyword option. This also gets fed into the parser. Because `load` is responsible for loading Ruby objects, the comments are then attached to the loaded objects via delegators that wraps the objects and stores the leading and trailing comments. Those objects are then taken into account in the various `dump` APIs to dump out the comments as well. For example:

```ruby
result = Psych::Pure.load("- a # comment1\n- c # comment2\n", comments: true)
# => ["a", "c"]

result.insert(1, "b")
# => ["a", "b", "c"]

puts Psych::Pure.dump(result)
# ---
# - a # comment1
# - b
# - c # comment2
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/kddnewton/psych-pure.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
