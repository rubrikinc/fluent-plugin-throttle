require 'bundler/setup'
require 'single_cov'

SingleCov.setup :minitest

require 'fluent/test'
require 'fluent/test/driver/input'
require 'fluent/test/driver/filter'
require 'fluent/test/driver/output'
require 'fluent/test/helpers'
require 'maxitest/autorun'
require 'mocha/minitest'
