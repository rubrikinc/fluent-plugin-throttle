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

    it 'does not throttle when log includes the key to ignore' do
      driver = create_driver <<~CONF
        group_key "group"
        group_bucket_period_s 1
        group_bucket_limit 15
        <ignore>
          key level
          regex /^([Ii]nfo|[Ii]nformation|[Dd]ebug)$/
        </ignore>
      CONF

      driver.run(default_tag: "test") do
        driver.feed([[event_time, {"msg": "test lower cased i", "level": "info", "group": "a"}]] * 10)
        driver.feed([[event_time, {"msg": "test capital I", "level": "Info", "group": "b"}]] * 10)
        driver.feed([[event_time, {"msg": "test lower cased i", "level": "information", "group": "b"}]] * 10)
        driver.feed([[event_time, {"msg": "test capital I", "level": "Information", "group": "b"}]] * 10)
        driver.feed([[event_time, {"msg": "test", "level": "error", "group": "a"}]] * 20)
        driver.feed([[event_time, {"msg": "test", "level": "error", "group": "b"}]] * 20)
      end

      assert_equal(70, driver.filtered_records.compact.length) # compact remove nils
    end

    it 'does not throttle when log includes the nested key to ignore' do
      driver = create_driver <<~CONF
        group_key "group"
        group_bucket_period_s 1
        group_bucket_limit 15
        <ignore>
          key app.version
          regex /^(2|3)$/
        </ignore>
      CONF

      driver.run(default_tag: "test") do
        driver.feed([[event_time, {"msg": "test lower cased i", "app": {"version": 2}, "group": "a"}]] * 10)
        driver.feed([[event_time, {"msg": "test lower cased i", "app": {"version": 3}, "group": "b"}]] * 10)
        driver.feed([[event_time, {"msg": "test lower cased i", "app": {"version": 4}, "group": "a"}]] * 20)
        driver.feed([[event_time, {"msg": "test lower cased i", "app": {"version": 5}, "group": "b"}]] * 20)
      end

      assert_equal(50, driver.filtered_records.compact.length) # compact remove nils
    end

    it 'does not throttle when nested key to ignore does not exists' do
      driver = create_driver <<~CONF
        group_key "group"
        group_bucket_period_s 1
        group_bucket_limit 15
        <ignore>
          key app.author
          regex /^(john|doe)$/
        </ignore>
      CONF

      driver.run(default_tag: "test") do
        driver.feed([[event_time, {"msg": "test lower cased i", "app": {"version": 2}, "group": "a"}]] * 10)
        driver.feed([[event_time, {"msg": "test lower cased i", "app": {"version": 3}, "group": "b"}]] * 10)
        driver.feed([[event_time, {"msg": "test lower cased i", "app": {"version": 4}, "group": "a"}]] * 20)
        driver.feed([[event_time, {"msg": "test lower cased i", "app": {"version": 5}, "group": "b"}]] * 20)
      end

      assert_equal(30, driver.filtered_records.compact.length) # compact remove nils
    end

    it 'does not throttle when key to ignore does not exists' do
      driver = create_driver <<~CONF
        group_key "group"
        group_bucket_period_s 1
        group_bucket_limit 15
        <ignore>
          key testKey
          regex /^(test|test2)$/
        </ignore>
      CONF

      driver.run(default_tag: "test") do
        driver.feed([[event_time, {"msg": "test lower cased i", "app": {"version": 2}, "group": "a"}]] * 10)
        driver.feed([[event_time, {"msg": "test lower cased i", "app": {"version": 3}, "group": "b"}]] * 10)
        driver.feed([[event_time, {"msg": "test lower cased i", "app": {"version": 4}, "group": "a"}]] * 20)
        driver.feed([[event_time, {"msg": "test lower cased i", "app": {"version": 5}, "group": "b"}]] * 20)
      end

      assert_equal(30, driver.filtered_records.compact.length) # compact remove nils
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
