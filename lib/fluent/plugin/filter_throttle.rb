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
      Override the default rate limit for a specific group. Example hash:
      {"group_key1_value,group_key2_value": { # comma separated if multiple group_key values are given
            "group_bucket_period_s": 60, # Remaining values match the default value names
            "group_bucket_limit": 10000,
            "group_drop_logs": true}
      }
    DESC
    config_param :group_override, :hash, :default => {}

    BucketConfig = Struct.new(
        :period_s,
        :limit,
        :drop_logs,
        :rate_limit,
        :gc_timeout_s,
        :reset_rate_s,
        :warning_delay_s)


    Group = Struct.new(
      :rate_count,
      :rate_last_reset,
      :aprox_rate,
      :bucket_count,
      :bucket_last_reset,
      :last_warning,
      :config)

    def create_override_bucket_configs(config_hash)
      config_hash.each do |group_key, config|
        group_key_value = group_key.split(',')
        period = config.fetch("group_bucket_period_s", @group_bucket_period_s)
        limit = config.fetch("group_bucket_limit", @group_bucket_limit)
        drop_logs = config.fetch("group_drop_logs", @group_drop_logs)
        rate_limit = (limit / period)
        gc_timeout_s = 2 * period
        reset_rate_s = config.fetch("group_reset_rate_s", rate_limit)
        warning_delay_s = config.fetch("group_warning_delay_s", @group_warning_delay_s)
        b = BucketConfig.new(period, limit, drop_logs, rate_limit, gc_timeout_s, reset_rate_s, warning_delay_s)
        @bucket_configs[group_key_value] = b
      end
    end

    def validate_bucket(n, b)
      raise "#{n} period_s must be > 0" unless b.period_s > 0
      raise "#{n} limit must be > 0" unless b.limit > 0
      raise "#{n} reset_rate_s must be > -1" unless b.reset_rate_s >= -1
      raise "#{n} reset_rate_s must be > limit \\ period_s" unless b.reset_rate_s <= b.rate_limit
      raise "#{n} warning_delay_s must be >= 1" unless b.warning_delay_s >= 1
    end

    def configure(conf)
      super

      # Set up default bucket & calculate derived values
      default_rate_limit = (@group_bucket_limit / @group_bucket_period_s)
      default_reset_rate_s = @group_reset_rate_s.nil? ? default_rate_limit : @group_reset_rate_s
      default_gc_timeout_s = 2 * @group_bucket_period_s
      default_bucket_config = BucketConfig.new(
        @group_bucket_period_s,
        @group_bucket_limit,
        @group_drop_logs,
        default_rate_limit,
        default_gc_timeout_s,
        default_reset_rate_s,
        @group_warning_delay_s)

      validate_bucket("default", default_bucket_config)
      @bucket_configs = Hash.new(default_bucket_config)
      # Parse override configs and add to bucket_configs
      create_override_bucket_configs(@group_override)

      # Make sure the config for each bucket are valid
      @bucket_configs.each do |key_path, config|
        validate_bucket(key_path, config)
      end


      @group_key_paths = group_key.map { |key| key.split(".") }
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
      now = Time.now
      group = extract_group(record)
      bucket_config = @bucket_configs[group]
      rate_limit_exceeded = bucket_config.drop_logs ? nil : record # return nil on rate_limit_exceeded to drop the record

      # Ruby hashes are ordered by insertion.
      # Deleting and inserting moves the item to the end of the hash (most recently used)
      counter = @counters[group] = @counters.delete(group) || Group.new(0, now, 0, 0, now, nil, bucket_config)

      counter.rate_count += 1
      since_last_rate_reset = now - counter.rate_last_reset
      if since_last_rate_reset >= 1
        # compute and store rate/s at most every second
        counter.aprox_rate = (counter.rate_count / since_last_rate_reset).round()
        counter.rate_count = 0
        counter.rate_last_reset = now
      end

      # try to evict the least recently used group
      lru_group, lru_counter = @counters.first
      if !lru_group.nil? && now - lru_counter.rate_last_reset > counter.config.gc_timeout_s
        @counters.delete(lru_group)
      end

      if (now.to_i / counter.config.period_s) \
          > (counter.bucket_last_reset.to_i / counter.config.period_s)
        # next time period reached.

        # wait until rate drops back down (if enabled).
        if counter.bucket_count == -1 and counter.config.reset_rate_s != -1
          if counter.aprox_rate < counter.config.reset_rate_s
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
      if counter.bucket_count > counter.config.limit
        log_rate_limit_exceeded(now, group, counter)
        counter.bucket_count = -1
        return rate_limit_exceeded
      end

      record
    end

    private

    def extract_group(record)
      @group_key_paths.map do |key_path|
        record.dig(*key_path) || record.dig(*key_path.map(&:to_sym))
      end
    end

    def log_rate_limit_exceeded(now, group, counter)
      emit = counter.last_warning == nil ? true \
        : (now - counter.last_warning) >= counter.config.warning_delay_s
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
       'period_s': counter.config.period_s,
       'limit': counter.config.limit,
       'rate_limit_s': counter.config.rate_limit,
       'reset_rate_s': counter.config.reset_rate_s}
    end
  end
end
