# frozen_string_literal: true
require_relative '../../helper'
require 'fluent/plugin/filter_throttle'

SingleCov.covered!

describe Fluent::Plugin::ThrottleFilter do
  include Fluent::Test::Helpers

  before do
    Fluent::Test.setup
  end

  def create_driver(conf='')
    Fluent::Test::Driver::Filter.new(Fluent::Plugin::ThrottleFilter).configure(conf)
  end

  describe '#configure' do
    it 'raises on invalid group_bucket_limit' do
      assert_raises { create_driver("group_bucket_limit 0") }
    end

    it 'raises on invalid group_bucket_period_s' do
      assert_raises { create_driver("group_bucket_period_s 0") }
    end

    it 'raises on invalid group_reset_rate_s' do
      assert_raises { create_driver("group_bucket_limit 10\ngroup_bucket_period_s 10\ngroup_reset_rate_s 2") }
    end

    it 'raises on invalid group_reset_rate_s' do
      assert_raises { create_driver("group_bucket_limit 10\ngroup_bucket_period_s 10\ngroup_reset_rate_s -2") }
    end

    it 'raises on invalid group_warning_delay_s' do
      assert_raises { create_driver("group_warning_delay_s 0") }
    end
  end

  it 'throttles per group' do
    driver = create_driver <<~CONF
      group_key "group"
      group_bucket_period_s 1
      group_bucket_limit 5
    CONF

    driver.run(default_tag: "test") do
      driver.feed([[event_time, {"msg": "test", "group": "a"}]] * 10)
      driver.feed([[event_time, {"msg": "test", "group": "b"}]] * 10)
    end

    groups = driver.filtered_records.group_by { |r| r[:group] }
    assert_equal(5, groups["a"].size)
    assert_equal(5, groups["b"].size)
  end

  it 'drops until rate drops below group_reset_rate_s' do
    driver = create_driver <<~CONF
      group_bucket_period_s 60
      group_bucket_limit 180
      group_reset_rate_s 2
    CONF

    logs_per_sec = [4, 4, 2, 1, 2]

    driver.run(default_tag: "test") do
      (0...logs_per_sec.size*60).each do |i|
        Time.stubs(now: Time.at(i))
        min = i / 60

        driver.feed([[event_time, min: min]] * logs_per_sec[min])
      end
    end

    groups = driver.filtered_records.group_by { |r| r[:min] }
    messages_per_minute = []
    (0...logs_per_sec.size).each do |min|
      messages_per_minute[min] = groups.fetch(min, []).size
    end

    assert_equal [
      180, # hits the limit in the first minute
      0,   # still >= group_reset_rate_s
      0,   # still >= group_reset_rate_s
      59,  # now < group_reset_rate_s, stop dropping logs (except the first log is dropped)
      120  # > group_reset_rate_s is okay now because haven't hit the limit
    ], messages_per_minute
  end
end
