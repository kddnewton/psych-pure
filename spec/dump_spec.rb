#!/usr/bin/env ruby

require "psych/pure"

index = 0
skips = ["KK5P.yaml"]
base = File.expand_path("../tmp/yaml-test-suite/src", __dir__)

(ENV["FOCUS"] ? [ENV["FOCUS"]] : Dir["*.yaml", base: base]).each do |filename|
  next if skips.include?(filename)

  fixture = Psych::Pure.load(File.read(File.join(base, filename)))[0]
  next if fixture["skip"] || fixture["fail"]

  source = +fixture["yaml"]
  source.gsub!(/␣/, " ")
  source.gsub!(/—*»/, "\t")
  source.gsub!(/⇔/, "\uFEFF")
  source.gsub!(/↵/, "")
  source.gsub!(/∎\n$/, "")

  loaded = Psych::Pure.unsafe_load(source)
  expected = Psych.dump(loaded)
  actual = Psych::Pure.dump(loaded)

  if expected == actual
    puts("ok #{index += 1} - #{filename}")
  else
    puts("not ok #{index += 1} - #{filename}")
    puts("#      expected: #{expected.inspect}")
    puts("#        actual: #{actual.inspect}")
  end
end

puts "1..#{index}"
