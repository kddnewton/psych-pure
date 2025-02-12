#!/usr/bin/env ruby

require "psych/pure"

# These tests are known to be incorrect on the Psych parser.
known_failures = [
  "2JQS.yaml",
  "2LFX.yaml",
  "2SXE.yaml",
  "4ABK.yaml",
  "4MUZ.yaml",
  "58MP.yaml",
  "5MUD.yaml",
  "5T43.yaml",
  "652Z.yaml",
  "6BCT.yaml",
  "6CA3.yaml",
  "6LVF.yaml",
  "6M2F.yaml",
  "8XYN.yaml",
  "96NN.yaml",
  "9SA2.yaml",
  "A2M4.yaml",
  "BEC7.yaml",
  "CFD4.yaml",
  "DBG4.yaml",
  "DK3J.yaml",
  "DK95.yaml",
  "FP8R.yaml",
  "FRK4.yaml",
  "HM87.yaml",
  "HWV9.yaml",
  "J7PZ.yaml",
  "K3WX.yaml",
  "M2N8.yaml",
  "NHX8.yaml",
  "NJ66.yaml",
  "NKF9.yaml",
  "Q5MG.yaml",
  "QT73.yaml",
  "R4YG.yaml",
  "S3PD.yaml",
  "S4JQ.yaml",
  "S4JQ.yaml",
  "UKK6.yaml",
  "UT92.yaml",
  "W4TN.yaml",
  "W5VH.yaml",
  "Y2GN.yaml"
]

# These tests are known to contain empty streams. The Psych parser treats
# that as "false" while Psych::Pure treats it as "nil".
known_empties = [
  "8G76.yaml",
  "98YD.yaml",
  "AVM7.yaml"
]

index = 0
skips = known_failures | known_empties
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

  expected = Psych.unsafe_load(source)
  actual = Psych::Pure.unsafe_load(source)

  if expected == actual
    puts("ok #{index += 1} - #{filename}")
  else
    puts("not ok #{index += 1} - #{filename}")
    puts("#      expected: #{expected.inspect}")
    puts("#        actual: #{actual.inspect}")
  end
end

puts "1..#{index}"
