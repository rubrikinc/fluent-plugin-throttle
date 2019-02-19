# fluent-plugin-throttle

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://github.com/rubrikinc/fluent-plugin-throttle/blob/master/LICENSE)

A sentry pluging to throttle logs. Logs are grouped by a configurable key. When
a group exceeds a configuration rate, logs are dropped for this group.

## Installation

install with `gem` or td-agent provided command as:

```bash
# for fluentd
$ gem install fluent-plugin-throttle
```

## Usage

```xml
<filter **>
  @type throttle
  group_key kubernetes.container_name
  group_bucket_period_s   60
  group_bucket_limit    6000
  group_reset_rate_s     100
</filter>
```

## Configuration

#### group\_key

Default: `kubernetes.container_name`.

Used to group logs. Groups are rate limited independently.

A dot indicates a key within a sub-object. As an example, in the following log,
the group key resolve to "random":
```
{"level": "error", "msg": "plugin test", "kubernetes": { "container_name": "random" } }
```

Multiple groups can be specified using the fluentd config array syntax, 
e.g. `kubernetes.container_name,kubernetes.pod_name`, in which case each unique pair
of key values are rate limited independently.

If the group cannot be resolved, an anonymous (`nil`) group is used for rate limiting.

#### group\_bucket\_period\_s

Default: `60` (60 second).

This is the period of of time over which `group_bucket_limit` applies.

#### group\_bucket\_limit

Default: `6000` (logs per `group_bucket_period_s`).

Maximum number logs allowed per groups over the period of `group_bucket_period_s`.

This translate to a log rate of `group_bucket_limit/group_bucket_period_s`.
When a group exceeds this rate, logs from this group are dropped.

For example, the default is 6000/60s, making for a rate of 100 logs per
seconds.

Note that this is not expressed as a rate directly because there is a
difference between the overall rate and the distribution of logs over a period
time. For example, a burst of logs in the middle of a minute bucket might not
exceed the average rate of the full minute.

Consider `60/60s`, 60 logs over a minute, versus `1/1s`, 1 log per second.
Over a minute, both will emit a maximum of 60 logs. Limiting to a rate of 60
logs per minute. However `60/60s` will readily emit 60 logs within the first
second then nothing for the remaining 59 seconds. While the `1/1s` will only
emit the first log of every second.

#### group\_drop\_logs

Default: `true`.

When a group reaches its limit, logs will be dropped from further processing
if this value is true (set by default). To prevent the logs from being dropped
and only receive a warning message when rate limiting would have occurred, set
this value for false. This can be useful to fine-tune your group bucket limits
before dropping any logs.

#### group\_reset\_rate\_s

Default: `group_bucket_limit/group_bucket_period_s` (logs per `group_bucket_period_s`).
Maximum: `group_bucket_limit/group_bucket_period_s`.

After a group has exceeded its bucket limit, logs are dropped until the rate
per second falls below or equal to `group_reset_rate_s`.

The default value is `group_bucket_limits/group_bucket_period_s`. For example
for 3600 logs per hour, the reset will defaults to `3600/3600s = 1/s`, one log
per second.

Taking the example `3600 log/hour` with the default reset rate of `1 log/s`
further:

 - Let's say we have a period of 10 hours.
 - During the first hour, 2 logs/s are produced. After 30 minutes, the hourly
   bucket has reached its limit, and logs are dropped. At this point the rate
   is still 2 logs/s for the remaining 30 minutes.
 - Because the last hour finished on 2 logs/s, which is higher that the
   `1 log/s` reset, all logs are still dropped when starting the second hour. The
   bucket limit is left untouched since nothing is being emitted.
 - Now, at 2 hours and 30 minutes, the log rate halves to `1 log/s`, which is
   equal to the reset rate. Logs are emitted again, counting toward the bucket
   limit as normal. Allowing up to 3600 logs for the last 30 minutes of the second
   hour.

Because this could allow for some instability if the log rate hovers around the
`group_bucket_limit/group_bucket_period_s` rate, it is possible to set a
different reset rate.

Note that a value of `0` effectively means the plugin will drops logs forever
after a single breach of the limit until the next restart of fluentd.

A value of `-1` disables the feature.

#### group\_warning\_delay\_s

Default: `10` (seconds).

When a group reaches its limit and as long as it is not reset, a warning
message with the current log rate of the group is emitted repeatedly. This is
the delay between every repetition.

#### ignore

Default: `none`

Define which records you want to ignore, you should specify key and regex to filter by.

Example:

```
        <ignore>
          key app.version
          regex /^(2|3)$/
        </ignore>
```

A dot indicates a key within a sub-object. As an example, in the following log,
the group key resolve to "2":
```
{"level": "error", "msg": "plugin test", "app": { "version": "2" } }
```

Will not take into throttling bucket calculations records that has version 2 or 3,
They will just pass-through.

## License

Apache License, Version 2.0

## Copyright

Copyright © 2018 ([Rubrik Inc.](https://www.rubrik.com))
