# frozen_string_literal: true
require_relative '../../helper'
require 'fluent/plugin/filter_throttle'

SingleCov.covered!

describe Fluent::Plugin::ThrottleFilter do
  include Fluent::Test::Helpers

  before do
    Fluent::Test.setup
  end

  after do
    if instance_variable_defined?(:@driver)
      assert @driver.error_events.empty?, "Errors detected: " + @driver.error_events.map(&:inspect).join("\n")
    end
  end

  def create_driver(conf='')
    @driver = Fluent::Test::Driver::Filter.new(Fluent::Plugin::ThrottleFilter).configure(conf)
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

  describe '#filter' do
    it 'throttles per group key' do
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

    it 'rejects override configurations with invalid values' do
      assert_raises { create_driver <<~CONF
        group_key "group"
        group_bucket_period_s 1
        group_bucket_limit 5
        group_override {"group_bucket_1":{
          "group_bucket_period_s": -1,
          "group_bucket_limit": 7,
          "group_drop_logs": true
        }}
      CONF
      }
    end

    it 'throttles with different rates in override configs' do
      driver = create_driver <<~CONF
        group_key "group"
        group_bucket_period_s 1
        group_bucket_limit 5
        group_override {"group_bucket_1":{
          "group_bucket_period_s": 1,
          "group_bucket_limit": 7,
          "group_drop_logs": true
        }}
      CONF

      driver.run(default_tag: "test") do
        driver.feed([[event_time, {"msg": "test", "group": "a"}]] * 10)
        driver.feed([[event_time, {"msg": "test", "group": "b"}]] * 10)
        driver.feed([[event_time, {"msg": "test", "group": "group_bucket_1"}]] * 10)
      end

      groups = driver.filtered_records.group_by { |r| r[:group] }
      assert_equal(5, groups["a"].size)
      assert_equal(5, groups["b"].size)
      assert_equal(7, groups["group_bucket_1"].size)
    end

    it 'allows composite group keys' do
      driver = create_driver <<~CONF
        group_key "group1,group2"
        group_bucket_period_s 1
        group_bucket_limit 5
      CONF

      driver.run(default_tag: "test") do
        driver.feed([[event_time, {"msg": "test", "group1": "a", "group2": "b"}]] * 10)
        driver.feed([[event_time, {"msg": "test", "group1": "b", "group2": "b"}]] * 10)
        driver.feed([[event_time, {"msg": "test", "group1": "c"}]] * 10)
        driver.feed([[event_time, {"msg": "test", "group2": "c"}]] * 10)
      end

      groups = driver.filtered_records.group_by { |r| r[:group1] }
      groups.each { |k, g| groups[k] = g.group_by { |r| r[:group2] } }

      assert_equal(5, groups["a"]["b"].size)
      assert_equal(5, groups["b"]["b"].size)
      assert_equal(5, groups["c"][nil].size)
      assert_equal(5, groups[nil]["c"].size)
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

    it 'removes lru groups after 2*period' do
      driver = create_driver <<~CONF
        group_key "group"
        group_bucket_period_s 2
        group_bucket_limit 6
        group_reset_rate_s 2
      CONF

      driver.run(default_tag: "test") do
        Time.stubs(now: Time.at(1))
        driver.feed([[event_time, {"msg": "test", "group": "a"}]] * 2)
        Time.stubs(now: Time.at(10))
        driver.feed([[event_time, {"msg": "test", "group": "b"}]] * 2)
      end
      #  TODO: Figure out how to assert the group was removed from the private variable
    end

    it 'does not throttle when in log only mode' do
      driver = create_driver <<~CONF
        group_bucket_period_s 2
        group_bucket_limit 4
        group_reset_rate_s 2
        group_drop_logs false
      CONF

      records_expected = 0
      driver.run(default_tag: "test") do
        (0...10).each do |i|
          Time.stubs(now: Time.at(i))
          count = [1,8 - i].max
          records_expected += count
          driver.feed((0...count).map { |j| [event_time, msg: "test#{i}-#{j}"] }) # * count)
        end
      end

      assert_equal records_expected, driver.filtered_records.size
      assert driver.logs.any? { |log| log.include?('rate exceeded') }
      assert driver.logs.any? { |log| log.include?('rate back down') }
    end
  end

  describe 'logging' do
    it 'logs when rate exceeded once per group_warning_delay_s' do
      driver = create_driver <<~CONF
        group_bucket_period_s 2
        group_bucket_limit 2
        group_warning_delay_s 3
      CONF

      logs_per_sec = 4

      driver.run(default_tag: "test") do
        (0...10).each do |i|
          Time.stubs(now: Time.at(i))
          driver.feed([[event_time, msg: "test"]] * logs_per_sec)
        end
      end

      assert_equal 4, driver.logs.select { |log| log.include?('rate exceeded') }.size
    end

    it 'logs when rate drops below group_reset_rate_s' do
      driver = create_driver <<~CONF
        group_bucket_period_s 2
        group_bucket_limit 4
        group_reset_rate_s 2
      CONF

      driver.run(default_tag: "test") do
        (0...10).each do |i|
          Time.stubs(now: Time.at(i))
          driver.feed([[event_time, msg: "test"]] * [1,8 - i].max)
        end
      end

      assert driver.logs.any? { |log| log.include?('rate back down') }
    end
  end
end
