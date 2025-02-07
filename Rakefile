# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/clean"

directory "tmp"

directory "tmp/yaml-test-suite" => "tmp" do
  sh("git clone --depth 1 https://github.com/yaml/yaml-test-suite.git tmp/yaml-test-suite")
end

directory "tmp/yaml-test-suite/testml" => "tmp/yaml-test-suite" do
  Dir.chdir("tmp/yaml-test-suite") { sh("make testml") }
end

directory "tmp/testml" => "tmp" do
  # Waiting on https://github.com/testml-lang/testml/pull/64.
  # system("git clone --depth 1 https://github.com/testml-lang/testml.git tmp/testml")
  sh("git clone -b ruby --depth 1 https://github.com/kddnewton/testml.git tmp/testml")
end

file "tmp/yaml-test-suite.tml" => "tmp/yaml-test-suite/testml" do
  File.open("tmp/yaml-test-suite.tml", "w") do |file|
    Dir["tmp/yaml-test-suite/testml/*.tml"].each do |filepath|
      line = File.open(filepath, &:readline).strip
      file.puts(line.sub("===", "%Import").sub("-", "    # "))
    end
  end
end

task "spec" => ["tmp/testml", "tmp/yaml-test-suite.tml"] do
  env = {
    "PATH" => "#{File.expand_path("tmp/testml/bin", __dir__)}:#{ENV["PATH"]}",
    "TESTML_BRIDGE" => "bridge",
    "TESTML_RUN" => "ruby-tap",
    "TESTML_LIB" => "#{File.expand_path("tmp", __dir__)}:#{File.expand_path("tmp/yaml-test-suite/testml", __dir__)}"
  }

  sh(env, "prove -v spec/*.tml spec/*_spec.rb")
end

task "default" => "spec"

CLEAN.include("test/.testml")
CLEAN.include("tmp")
