# frozen_string_literal: true

require_relative "lib/psych/pure/version"

version = Psych::Pure::VERSION
repository = "https://github.com/kddnewton/psych-pure"

Gem::Specification.new do |spec|
  spec.name = "psych-pure"
  spec.version = version
  spec.authors = ["Kevin Newton"]
  spec.email = ["kddnewton@gmail.com"]

  spec.summary = "A YAML parser written in Ruby"
  spec.homepage = repository
  spec.license = "MIT"

  spec.metadata = {
    "bug_tracker_uri" => "#{repository}/issues",
    "changelog_uri" => "#{repository}/blob/v#{version}/CHANGELOG.md",
    "source_code_uri" => repository,
    "rubygems_mfa_required" => "true"
  }

  spec.files = %w[
    CHANGELOG.md
    CODE_OF_CONDUCT.md
    LICENSE
    README.md
    psych-pure.gemspec
    lib/psych/pure.rb
    lib/psych/pure/version.rb
  ]

  spec.require_paths = ["lib"]

  spec.add_dependency "psych"
  spec.add_dependency "strscan"

  spec.add_development_dependency "bundler"
  spec.add_development_dependency "rake"
end
