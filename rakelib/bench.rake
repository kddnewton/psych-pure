# frozen_string_literal: true

# ---------------------------------------------------------------------------
# Fixture generators — each returns a YAML string exercising one feature.
# ---------------------------------------------------------------------------

BENCH_FEATURES = {
  "plain scalars" => -> (count = 200) {
    (1..count).map { |index| "key#{index}: value#{index}" }.join("\n")
  },
  "quoted scalars" => -> (count = 200) {
    (1..count).flat_map { |index|
      [
        "single#{index}: 'hello world #{index}'",
        "double#{index}: \"hello\\tworld\\n#{index}\""
      ]
    }.join("\n")
  },
  "integer scalars" => -> (count = 200) {
    (1..count).map { |index| "int#{index}: #{index * 137}" }.join("\n")
  },
  "float scalars" => -> (count = 200) {
    (1..count).map { |index| "float#{index}: #{index * 3.14159}" }.join("\n")
  },
  "bool/null scalars" => -> (count = 200) {
    (1..count).map { |index|
      case index % 4
      when 0 then "b#{index}: true"
      when 1 then "b#{index}: false"
      when 2 then "b#{index}: null"
      when 3 then "b#{index}: ~"
      end
    }.join("\n")
  },
  "literal blocks" => -> (count = 50) {
    (1..count).map { |index|
      "block#{index}: |\n" + (1..8).map { |line| "  line #{line} of block #{index}" }.join("\n")
    }.join("\n")
  },
  "folded blocks" => -> (count = 50) {
    (1..count).map { |index|
      "folded#{index}: >\n" + (1..8).map { |line| "  line #{line} of folded #{index}" }.join("\n")
    }.join("\n")
  },
  "nested mappings" => -> (depth = 20) {
    yaml = +""
    depth.times { |level| yaml << "  " * level << "level#{level}:\n" }
    yaml << "  " * depth << "value: leaf\n"
    yaml
  },
  "block sequences" => -> (count = 200) {
    "items:\n" + (1..count).map { |index| "  - item#{index}" }.join("\n")
  },
  "nested sequences" => -> (depth = 15) {
    yaml = +""
    depth.times { |level| yaml << "  " * level << "- \n" }
    yaml << "  " * depth << "- leaf"
    yaml
  },
  "flow sequences" => -> (count = 50) {
    items = (1..20).map { |index| "item#{index}" }.join(", ")
    (1..count).map { |index| "list#{index}: [#{items}]" }.join("\n")
  },
  "flow mappings" => -> (count = 50) {
    pairs = (1..10).map { |index| "k#{index}: v#{index}" }.join(", ")
    (1..count).map { |index| "map#{index}: {#{pairs}}" }.join("\n")
  },
  "anchors & aliases" => -> (count = 50) {
    anchors = (1..count).map { |index| "anchor#{index}: &a#{index}\n  x: #{index}\n  y: #{index * 2}" }.join("\n")
    aliases = (1..count).map { |index| "ref#{index}: *a#{index}" }.join("\n")
    "#{anchors}\n#{aliases}"
  },
  "tagged values" => -> (count = 100) {
    (1..count).map { |index|
      case index % 3
      when 0 then "t#{index}: !!str #{index}"
      when 1 then "t#{index}: !!int '#{index}'"
      when 2 then "t#{index}: !!float '#{index}.0'"
      end
    }.join("\n")
  },
  "multi-document" => -> (count = 50) {
    (1..count).map { |index|
      "---\ntitle: Document #{index}\nvalue: #{index}\n"
    }.join
  },
  "comments" => -> (count = 200) {
    (1..count).map { |index|
      "# Comment for key #{index}\nkey#{index}: value#{index} # inline comment"
    }.join("\n")
  },
  "complex keys" => -> (count = 50) {
    (1..count).map { |index|
      "? |-\n  complex key #{index}\n: value#{index}"
    }.join("\n")
  },
  "mixed realistic" => -> {
    <<~YAML
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: app-config
        namespace: production
        labels:
          app: myapp
          tier: backend
          version: "2.1.0"
        annotations:
          description: "Application configuration for production deployment"
      data:
        database.yml: |
          production:
            adapter: postgresql
            host: db.example.com
            port: 5432
            database: myapp_production
            pool: 25
            timeout: 5000
        features: &default_features
          enable_caching: true
          enable_logging: true
          log_level: info
          max_retries: 3
          timeout_seconds: 30
        staging_features:
          <<: *default_features
          log_level: debug
          enable_profiling: true
        endpoints:
          - name: api
            port: 8080
            protocol: TCP
            health_check: /healthz
          - name: metrics
            port: 9090
            protocol: TCP
            health_check: /metrics
          - name: grpc
            port: 50051
            protocol: TCP
        users:
          admin: {role: admin, permissions: [read, write, delete]}
          viewer: {role: viewer, permissions: [read]}
        message: >
          This is a long folded string that spans
          multiple lines and will be folded into
          a single line with a trailing newline.
        notes: |-
          Line 1
          Line 2
          Line 3
        empty_value:
        null_value: ~
        enabled: true
        count: 42
        ratio: 3.14
    YAML
  }
}

BENCH_FIXTURE_DIR = "tmp/bench-fixtures"

BENCH_REPOS = {
  # Kubernetes examples — complex manifests with anchors, nested mappings
  "kubernetes" => {
    repo: "https://github.com/kubernetes/examples.git",
    sparse: ["**/*.yaml", "**/*.yml"]
  },
  # Ansible examples — playbooks with anchors, handlers, roles
  "ansible" => {
    repo: "https://github.com/ansible/ansible-examples.git",
    sparse: ["**/*.yaml", "**/*.yml"]
  },
  # Home Assistant core — deeply nested config YAML
  "home-assistant" => {
    repo: "https://github.com/home-assistant/core.git",
    sparse: ["homeassistant/components/*/manifest.json", "tests/fixtures/**/*.yaml"]
  },
  # GitLab CI templates — pipeline YAML
  "gitlab-ci" => {
    repo: "https://gitlab.com/gitlab-org/gitlab.git",
    sparse: ["lib/gitlab/ci/templates/**/*.yml"]
  }
}

BENCH_PROFILE_YAML = <<~YAML
  apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: web-app
    labels: &labels
      app: web
      tier: frontend
  spec:
    replicas: 3
    selector:
      matchLabels:
        <<: *labels
    template:
      metadata:
        labels:
          <<: *labels
      spec:
        containers:
          - name: web
            image: "nginx:1.25"
            ports:
              - containerPort: 80
                protocol: TCP
            env:
              - name: DATABASE_URL
                value: "postgres://db:5432/app"
              - name: REDIS_URL
                value: "redis://cache:6379"
            resources:
              limits: {cpu: "500m", memory: "128Mi"}
              requests: {cpu: "250m", memory: "64Mi"}
            livenessProbe:
              httpGet:
                path: /healthz
                port: 80
              initialDelaySeconds: 30
              periodSeconds: 10
          - name: sidecar
            image: "fluentd:v1.16"
            volumeMounts:
              - name: logs
                mountPath: /var/log
        volumes:
          - name: logs
            emptyDir: {}
        nodeSelector:
          disktype: ssd
        tolerations:
          - key: "dedicated"
            operator: "Equal"
            value: "web"
            effect: "NoSchedule"
  ---
  apiVersion: v1
  kind: Service
  metadata:
    name: web-service
    annotations:
      description: >
        This service exposes the web application
        to the internal cluster network.
  spec:
    type: ClusterIP
    ports:
      - port: 80
        targetPort: 80
        protocol: TCP
    selector:
      app: web
      tier: frontend
YAML

# ---------------------------------------------------------------------------
# Helper to load parseable YAML sources from a list of file paths.
# ---------------------------------------------------------------------------

def bench_load_sources(yaml_files)
  yaml_files.filter_map do |filepath|
    source = File.read(filepath)
    next if source.empty?

    begin
      Psych.unsafe_load(source)
      source
    rescue Psych::SyntaxError, Psych::BadAlias, Psych::DisallowedClass
      nil
    end
  end
end

def bench_compare(sources)
  Benchmark.ips do |bench|
    bench.report("Psych") { sources.each { |source| Psych.unsafe_load(source) } }
    bench.report("Psych::Pure") { sources.each { |source| Psych::Pure.unsafe_load(source) } }
    bench.compare!
  end
end

# ---------------------------------------------------------------------------
# Tasks
# ---------------------------------------------------------------------------

namespace "bench" do
  desc "Download real-world YAML fixtures for benchmarking"
  task "setup" => "tmp" do
    mkdir_p BENCH_FIXTURE_DIR

    BENCH_REPOS.each do |name, config|
      dest = "#{BENCH_FIXTURE_DIR}/#{name}"
      next if Dir.exist?(dest)

      puts "Cloning #{name}..."
      begin
        sh("git clone --depth 1 --filter=blob:none --sparse #{config[:repo]} #{dest}")
        sh("git -C #{dest} sparse-checkout add #{config[:sparse].map { |pattern| "'#{pattern}'" }.join(" ")}")
      rescue => error
        puts "  Warning: failed to clone #{name}: #{error.message}"
        rm_rf dest
      end
    end

    # Also generate large synthetic fixtures using the feature generators
    synth_dir = "#{BENCH_FIXTURE_DIR}/synthetic"
    unless Dir.exist?(synth_dir)
      mkdir_p synth_dir

      {
      "large-flat.yaml" => BENCH_FEATURES["plain scalars"].call(2000),
      "deep-nested.yaml" => BENCH_FEATURES["nested mappings"].call(50),
      "large-sequence.yaml" => BENCH_FEATURES["block sequences"].call(2000),
      "anchor-heavy.yaml" => BENCH_FEATURES["anchors & aliases"].call(200),
      "multi-document.yaml" => BENCH_FEATURES["multi-document"].call(200)
    }.each do |filename, content|
        File.write("#{synth_dir}/#{filename}", content)
      end
    end

    puts "Done! Fixtures in #{BENCH_FIXTURE_DIR}"
  end

  desc "Benchmark yaml-test-suite fixtures (Psych vs Psych::Pure)"
  task "suite" => "tmp/yaml-test-suite" do
    require "benchmark/ips"
    require "psych/pure"

    sources =
      Dir["tmp/yaml-test-suite/src/*.yaml"].filter_map do |filepath|
        fixture = Psych::Pure.load_file(filepath)[0]
        next if fixture["skip"] || fixture["fail"]

        source = +fixture["yaml"]
        source.gsub!(/␣|—*»|⇔|↵|∎\n$/) do |match|
          case match
          when "␣" then " "
          when "⇔" then "\uFEFF"
          when "↵" then ""
          when /∎\n$/ then ""
          else "\t"
          end
        end

        begin
          Psych.unsafe_load(source)
        rescue Psych::SyntaxError
          next
        end

        source
      end

    bench_compare(sources)
  end

  desc "Benchmark individual YAML features (filter with FILTER=pattern)"
  task "features" do
    require "benchmark/ips"
    require "psych/pure"

    filter = ENV["FILTER"]

    puts "psych-pure feature benchmarks"
    puts "=" * 60

    BENCH_FEATURES.each do |name, generator|
      next if filter && !name.include?(filter)

      source = generator.call
      bytes = source.bytesize
      puts
      puts "#{name} (#{bytes} bytes)"
      puts "-" * 60

      catch(:skip) do
        { "Psych" => Psych, "Psych::Pure" => Psych::Pure }.each do |label, parser|
          parser.parse(source)
        rescue StandardError => error
          puts "  SKIP (#{label} error: #{error.message})"
          throw :skip
        end

        bench_compare([source])
      end
    end
  end

  desc "Benchmark real-world YAML files (run bench:setup first)"
  task "realworld" => "bench:setup" do
    require "benchmark/ips"
    require "psych/pure"

    yaml_files = Dir["#{BENCH_FIXTURE_DIR}/**/*.{yml,yaml}"].sort

    if yaml_files.empty?
      abort "No YAML files found in #{BENCH_FIXTURE_DIR}."
    end

    groups = yaml_files.group_by { |filepath| filepath.sub("#{BENCH_FIXTURE_DIR}/", "").split("/").first }
    sources_by_group = groups.transform_values { |files| bench_load_sources(files) }

    puts "psych-pure real-world benchmarks"
    puts "=" * 60

    all_sources = sources_by_group.values.flatten
    total_bytes = all_sources.sum(&:bytesize)
    puts
    puts "ALL FILES: #{all_sources.size} files, #{total_bytes} bytes total"
    puts "-" * 60

    bench_compare(all_sources)

    sources_by_group.each do |project, sources|
      next if sources.empty?

      bytes = sources.sum(&:bytesize)
      puts
      puts "#{project}: #{sources.size} files, #{bytes} bytes"
      puts "-" * 60

      bench_compare(sources)
    end
  end

  desc "Profile Psych::Pure parsing (FILE=path/to/file.yaml, PROFILER=stackprof|ruby-prof)"
  task "profile" do
    require "psych/pure"

    profiler = ENV.fetch("PROFILER", "stackprof")
    unless %w[stackprof ruby-prof].include?(profiler)
      abort "Unknown profiler: #{profiler}. Use PROFILER=stackprof or PROFILER=ruby-prof."
    end

    source =
      if ENV["FILE"]
        File.read(ENV["FILE"])
      else
        BENCH_PROFILE_YAML
      end

    # Warmup
    10.times { Psych::Pure.unsafe_load(source) }

    iterations = Integer(ENV.fetch("ITERATIONS", "500"))
    puts "Profiling #{iterations} iterations of Psych::Pure.unsafe_load (#{source.bytesize} bytes)"
    puts

    case profiler
    when "stackprof"
      require "stackprof"

      profile = StackProf.run(mode: :cpu, interval: 100, raw: true) do
        iterations.times { Psych::Pure.unsafe_load(source) }
      end

      StackProf::Report.new(profile).print_text
    when "ruby-prof"
      require "ruby-prof"

      result = RubyProf.profile do
        iterations.times { Psych::Pure.unsafe_load(source) }
      end

      printer = RubyProf::FlatPrinter.new(result)
      printer.print($stdout, min_percent: 1)
    end
  end
end
