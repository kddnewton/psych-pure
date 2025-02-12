# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/clean"
require "rake/testtask"

file "cpanfile" do |task|
  File.write(task.name, <<~PERL)
    requires 'Capture::Tiny';
    requires 'Pegex';
    requires 'Tie::IxHash';
    requires 'YAML::PP';
  PERL
  puts "Wrote #{task.name}"
end

directory "tmp"

directory "tmp/yaml-test-suite" => "tmp" do |task|
  sh("git clone --depth 1 https://github.com/yaml/yaml-test-suite.git #{task.name}")
end

directory "tmp/yaml-test-suite/testml" => "tmp/yaml-test-suite" do |task|
  chdir(task.prerequisites.first) { sh("make testml") }
end

directory "tmp/testml" => "tmp" do |task|
  # Waiting on https://github.com/testml-lang/testml/pull/64.
  # system("git clone --depth 1 https://github.com/testml-lang/testml.git #{task.name}")
  sh("git clone -b ruby --depth 1 https://github.com/kddnewton/testml.git #{task.name}")
end

file "tmp/yaml-test-suite.tml" => "tmp/yaml-test-suite/testml" do |task|
  File.open(task.name, "w") do |file|
    Dir["#{task.prerequisites.first}/*.tml"].each do |filepath|
      line = File.open(filepath, &:readline).strip
      file.puts(line.sub("===", "%Import").sub("-", "    # "))
    end
  end
  puts "Wrote #{task.name}"
end

task "spec" => ["tmp/testml", "tmp/yaml-test-suite.tml"] do |task|
  env = {
    "PATH" => "#{File.expand_path("#{task.prerequisites.first}/bin", __dir__)}:#{ENV["PATH"]}",
    "TESTML_BRIDGE" => "bridge",
    "TESTML_RUN" => "ruby-tap",
    "TESTML_LIB" => "#{File.expand_path("tmp", __dir__)}:#{File.expand_path("tmp/yaml-test-suite/testml", __dir__)}"
  }

  sh(env, "prove -v #{task.name}/*.tml #{task.name}/*_spec.rb")
end

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

task "default" => ["spec", "test"]

CLEAN.include("cpanfile")
CLEAN.include("spec/.testml")
CLEAN.include("tmp")
