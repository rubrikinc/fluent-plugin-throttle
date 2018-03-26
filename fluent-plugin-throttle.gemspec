# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
  spec.name          = "fluent-plugin-throttle"
  spec.version       = "0.0.2"
  spec.authors       = ["François-Xavier Bourlet"]
  spec.email         = ["fx.bourlet@rubrik.com"]
  spec.summary       = %q{Fluentd filter for throttling logs based on a configurable key.}
  spec.homepage      = "https://github.com/rubrikinc/fluent-plugin-throttle"
  spec.license       = "Apache-2.0"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 1.16"
  spec.add_development_dependency "rake", "~> 12.3"
  spec.add_development_dependency "webmock", "~> 3.3"
  spec.add_development_dependency "test-unit", "~> 3.2"
  spec.add_development_dependency "appraisal", "~> 2.2"

  spec.add_runtime_dependency "fluentd", "~> 1.1"
end
