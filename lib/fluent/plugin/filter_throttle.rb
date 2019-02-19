# frozen_string_literal: true
require 'fluent/plugin/filter'

module Fluent::Plugin
  class ThrottleFilter < Filter
    Fluent::Plugin.register_filter('throttle', self)

    desc "Used to group logs. Groups are rate limited independently"
    config_param :group_key, :array, :default => ['kubernetes.container_name']

    desc <<~DESC
      This is the period of of time over which group_bucket_limit applies
    DESC
    config_param :group_bucket_period_s, :integer, :default => 60

    desc <<~DESC
      Maximum number logs allowed per groups over the period of
      group_bucket_period_s
    DESC
    config_param :group_bucket_limit, :integer, :default => 6000

    desc "Whether to drop logs that exceed the bucket limit or not"
    config_param :group_drop_logs, :bool, :default => true

    desc <<~DESC
      After a group has exceeded its bucket limit, logs are dropped until the
      rate per second falls below or equal to group_reset_rate_s.
    DESC
    config_param :group_reset_rate_s, :integer, :default => nil

    desc <<~DESC
      When a group reaches its limit and as long as it is not reset, a warning
      message with the current log rate of the group is emitted repeatedly.
      This is the delay between every repetition.
    DESC
    config_param :group_warning_delay_s, :integer, :default => 10
    
    desc <<~DESC
      Defines records which should be excluded from the throttling counters
    DESC
    config_section :ignore, param_name: :ignores, multi: true do
      desc "The field name to which the regular expression is applied"
      config_param :key do |value|
        value.split(".")
      end
      desc "The regular expression"
      config_param :regex do |value|
        if value.start_with?("/") && value.end_with?("/")
          Regexp.compile(value[1..-2])
        else
          Regexp.compile(value)
        end
      end
    end


    Group = Struct.new(
      :rate_count,
      :rate_last_reset,
      :aprox_rate,
      :bucket_count,
      :bucket_last_reset,
      :last_warning)

    def configure(conf)
      super

      @group_key_paths = group_key.map { |key| key.split(".") }

      raise "group_bucket_period_s must be > 0" \
        unless @group_bucket_period_s > 0

      raise "group_bucket_limit must be > 0" \
        unless @group_bucket_limit > 0

      @group_rate_limit = (@group_bucket_limit / @group_bucket_period_s)

      @group_reset_rate_s = @group_rate_limit \
        if @group_reset_rate_s == nil

      raise "group_reset_rate_s must be >= -1" \
        unless @group_reset_rate_s >= -1
      raise "group_reset_rate_s must be <= group_bucket_limit / group_bucket_period_s" \
        unless @group_reset_rate_s <= @group_rate_limit

      raise "group_warning_delay_s must be >= 1" \
        unless @group_warning_delay_s >= 1
    end

    def start
      super

      @counters = {}
    end

    def shutdown
      log.debug("counters summary: #{@counters}")
      super
    end

    def filter(tag, time, record)
      unless @ignores.empty?
        @ignores.each { |ignore|
          keysValue = extract_value_from_key_path(ignore.key, record)
          if keysValue != nil && ignore.regex.match(keysValue.to_s)
              return record
          end
        }
      end
      
      now = Time.now
      rate_limit_exceeded = @group_drop_logs ? nil : record # return nil on rate_limit_exceeded to drop the record
      group = extract_value_from_key_paths(@group_key_paths, record)
      counter = (@counters[group] ||= Group.new(0, now, 0, 0, now, nil))
      counter.rate_count += 1

      since_last_rate_reset = now - counter.rate_last_reset
      if since_last_rate_reset >= 1
        # compute and store rate/s at most every seconds.
        counter.aprox_rate = (counter.rate_count / since_last_rate_reset).round()
        counter.rate_count = 0
        counter.rate_last_reset = now
      end

      if (now.to_i / @group_bucket_period_s) \
          > (counter.bucket_last_reset.to_i / @group_bucket_period_s)
        # next time period reached.

        # wait until rate drops back down (if enabled).
        if counter.bucket_count == -1 and @group_reset_rate_s != -1
          if counter.aprox_rate < @group_reset_rate_s
            log_rate_back_down(now, group, counter)
          else
            log_rate_limit_exceeded(now, group, counter)
            return rate_limit_exceeded
          end
        end

        # reset counter for the rest of time period.
        counter.bucket_count = 0
        counter.bucket_last_reset = now
      else
        # if current time period credit is exhausted, drop the record.
        if counter.bucket_count == -1
          log_rate_limit_exceeded(now, group, counter)
          return rate_limit_exceeded
        end
      end

      counter.bucket_count += 1

      # if we are out of credit, we drop logs for the rest of the time period.
      if counter.bucket_count > @group_bucket_limit
        log_rate_limit_exceeded(now, group, counter)
        counter.bucket_count = -1
        return rate_limit_exceeded
      end

      record
    end

    private

    def extract_value_from_key_paths(paths, record)
      paths.map do |key_path|
        extract_value_from_key_path(key_path, record)
      end
    end

    def extract_value_from_key_path(path, record)
      record.dig(*path) || record.dig(*path.map(&:to_sym))
    end

    def log_rate_limit_exceeded(now, group, counter)
      emit = counter.last_warning == nil ? true \
        : (now - counter.last_warning) >= @group_warning_delay_s
      if emit
        log.warn("rate exceeded", log_items(now, group, counter))
        counter.last_warning = now
      end
    end

    def log_rate_back_down(now, group, counter)
      log.info("rate back down", log_items(now, group, counter))
    end

    def log_items(now, group, counter)
      since_last_reset = now - counter.bucket_last_reset
      rate = since_last_reset > 0 ? (counter.bucket_count / since_last_reset).round : Float::INFINITY
      aprox_rate = counter.aprox_rate
      rate = aprox_rate if aprox_rate > rate

      {'group_key': group,
       'rate_s': rate,
       'period_s': @group_bucket_period_s,
       'limit': @group_bucket_limit,
       'rate_limit_s': @group_rate_limit,
       'reset_rate_s': @group_reset_rate_s}
    end
  end
end
