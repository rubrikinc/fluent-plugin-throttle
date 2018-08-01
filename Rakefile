require 'bundler/gem_tasks'
require 'rake/testtask'

task default: [:test]
Rake::TestTask.new do |test|
  test.libs << 'lib' << 'test'
  test.test_files = FileList['test/**/*_test.rb']
  test.options = '-v'
end
