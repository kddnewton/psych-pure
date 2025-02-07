# Psych::Pure

[![Build Status](https://github.com/kddnewton/psych-pure/workflows/Main/badge.svg)](https://github.com/kddnewton/active_record-union_relation/actions)
[![Gem Version](https://img.shields.io/gem/v/psych-pure.svg)](https://rubygems.org/gems/psych-pure)

`Psych::Pure` is a YAML 1.2 library written in Ruby. It functions as an alternative to `Psych::Parser`, the main CRuby YAML library. The circumstances under which you may choose this library instead are:

* You have some issue installing `libyaml` and/or you want to avoid a native dependency.
* You have a need to parse comments from YAML source and/or to write comments out to YAML source.
* You do not care about performance (`Psych::Pure` is significantly slower and less efficient than `Psych::Parser`).

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

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/kddnewton/psych-pure.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
