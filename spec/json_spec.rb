#!/usr/bin/env ruby

require "json"
require "psych/pure"

# These tests are known to be incorrect on the Psych parser.
known_failures = [
  "J7PZ.yaml",
  "S4JQ.yaml"
]

# Psych::Pure knows about symbols, but yaml-test-suite does not. When we load
# them and then dump to JSON, they will not match. As such, we skip these tests.
known_symbols = [
  "2EBW.yaml",
  "58MP.yaml",
  "5T43.yaml",
  "DBG4.yaml",
  "FBC9.yaml",
  "HM87.yaml",
  "S7BG.yaml"
]

index = 0
skips = known_failures | known_symbols
base = File.expand_path("../tmp/yaml-test-suite/src", __dir__)

(ENV["FOCUS"] ? [ENV["FOCUS"]] : Dir["*.yaml", base: base]).each do |filename|
  next if skips.include?(filename)

  fixture = Psych::Pure.load(File.read(File.join(base, filename)))[0]
  next if fixture["skip"] || fixture["fail"] || !fixture["json"]

  expected =
    begin
      JSON.parse(fixture["json"])
    rescue JSON::ParserError
      next
    end

  source = +fixture["yaml"]
  source.gsub!(/␣/, " ")
  source.gsub!(/—*»/, "\t")
  source.gsub!(/⇔/, "\uFEFF")
  source.gsub!(/↵/, "")
  source.gsub!(/∎\n$/, "")

  actual =
    begin
      JSON.load(JSON.dump(Psych::Pure.unsafe_load(source)))
    rescue JSON::GeneratorError
      next
    end

  if expected == actual
    puts("ok #{index += 1} - #{filename}")
  else
    puts("not ok #{index += 1} - #{filename}")
    puts("#      expected: #{expected.inspect}")
    puts("#        actual: #{actual.inspect}")
  end
end

puts "1..#{index}"
