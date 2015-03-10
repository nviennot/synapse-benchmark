#!/usr/bin/env ruby
require 'bundler'
require 'logger'
Bundler.require
require 'multi_json'
require 'optparse'

class Slice < Hashie::Mash
  def duration
    self.end - self.start
  end

  def include?(p)
    (self.start...self.end).include?(p)
  end

  def thread_id
    self.pid
  end
end

def parse_file(file)
  File.open(file).readlines.map do |line|
    next unless line =~ /^\[([^\]]+) ([0-9]+)-([0-9]+)\] ([^ ]+) ([0-9.]+)-([0-9.]+) (.*)$/
    begin
      options = {:app => $1, :pid => $2, :tid => $3, :type => $4.to_sym, :start => Float($5) * 1000, :end => Float($6) * 1000}
      options[:desc] = $7 unless $7.empty?
      slice = Slice.new(options)
      if slice.type == :app_controller && slice.desc =~ /(.+) -- (.+)/
        slice.desc = $1
        slice.read_deps = MultiJson.load($2)
      end
      if slice.type == :publish
        slice.payload = MultiJson.load(slice.desc)
        slice.payload_size = slice.desc.size
      end
      slice
    rescue Exception => e
      STDERR.puts "WARN: parse error #{e}"
    end
  end.compact
end

slices = parse_file(ARGV[0])
slices.sort_by!(&:start)

output = slices.map do |slice|
  if slice.type == :publish && slice.payload
    [slice, slice.payload['context'], slice.payload['real_deps']['read'], slice.payload_size] rescue nil
  elsif slice.type == :app_controller && slice.read_deps
    [slice, slice.desc, slice.read_deps]
  end
end.compact.reduce({}) do |results, (slice, controller, read_deps)|
  if controller =~ /^[^ ]+\/+[^ ]+$/
    results[controller] ||= { :read_deps               => 0,
                              :read_deps_with_tracking => 0,
                              :num_publish             => 0,
                              :num_controller_calls    => 0,
                              :read_only_deps          => 0,
                              :publish_duration        => 0.0,
                              :publish_durations       => [],
                              :publish_deps            => [],
                              :publish_sizes           => [],
                              :controller_duration     => 0.0,
                              :controller_durations    => [],
                              :controller_calls        => [] }

    r = results[controller]

    if slice.type == :publish
      r[:read_deps] += read_deps.flatten.uniq.size
      r[:read_deps_with_tracking] += read_deps.reject(&:empty?).uniq.size
      r[:num_publish] += 1
      r[:publish_duration] += slice.duration
      r[:publish_durations].push slice.duration
      r[:publish_deps].push read_deps.flatten.uniq.size
      r[:publish_sizes].push slice.payload_size

      # per call statistics:
      # assign the publish to the most recent call of this controller
      r[:controller_calls][-1][:deps] += read_deps.flatten.uniq.size
      r[:controller_calls][-1][:publish_duration] += slice.duration
      r[:controller_calls][-1][:num_publish] += 1
    end

    if slice.type == :app_controller
      r[:num_controller_calls] += 1
      r[:read_only_deps] += read_deps.flatten.uniq.size
      r[:controller_duration] += slice.duration
      r[:controller_durations].push slice.duration

      # per call statistics:
      # it is a new call so push it in the controller array
      r[:controller_calls].push({ :deps                => 0,
                                  :publish_duration    => 0,
                                  :num_publish         => 0,
                                  :controller_duration => slice.duration })
    end
  end

  results
end

output_normalized = Hash[output.map do |controller, r|
  r[:read_deps]               = (r[:read_deps]               / r[:num_controller_calls].to_f).round(2)
  r[:read_deps_with_tracking] = (r[:read_deps_with_tracking] / r[:num_controller_calls].to_f).round(2)
  r[:num_publish]             = (r[:num_publish]             / r[:num_controller_calls].to_f).round(2)
  r[:read_only_deps]          = (r[:read_only_deps]          / r[:num_controller_calls].to_f).round(2)
  r[:publish_duration]        = (r[:publish_duration]        / r[:num_controller_calls].to_f).round(2)
  r[:controller_duration]     = (r[:controller_duration]     / r[:num_controller_calls].to_f).round(2)

  # median and 99percentile metrics
  calls = r[:controller_calls]
  sorted_calls = calls.map { |call| call[:deps] }.sort
  r[:read_deps_median] = sorted_calls[(sorted_calls.count / 2).floor]
  r[:read_deps_95]     = sorted_calls[(sorted_calls.count * 0.95).floor]
  r[:read_deps_99]     = sorted_calls[(sorted_calls.count * 0.99).floor]
  r[:read_deps_avg]    = sorted_calls.reduce(&:+) / sorted_calls.count.to_f
  sorted_calls = calls.map { |call| call[:publish_duration] }.sort
  r[:publish_duration_median] = sorted_calls[(sorted_calls.count / 2).floor]
  r[:publish_duration_95]     = sorted_calls[(sorted_calls.count * 0.95).floor]
  r[:publish_duration_99]     = sorted_calls[(sorted_calls.count * 0.99).floor]
  r[:publish_duration_avg]    = sorted_calls.reduce(&:+) / sorted_calls.count.to_f
  sorted_calls = calls.map do |call|
    call[:controller_duration] == 0 ? 0 : (call[:publish_duration] /
                                           call[:controller_duration].to_f).round(2)
  end.sort
  r[:overhead_median] = sorted_calls[(sorted_calls.count / 2).floor]
  r[:overhead_95]     = sorted_calls[(sorted_calls.count * 0.95).floor]
  r[:overhead_99]     = sorted_calls[(sorted_calls.count * 0.99).floor]
  r[:overhead_avg]    = sorted_calls.reduce(&:+) / sorted_calls.count.to_f
  sorted_calls = calls.map { |call| call[:num_publish] }.sort
  r[:num_publish_median] = sorted_calls[(sorted_calls.count / 2).floor]
  r[:num_publish_95]     = sorted_calls[(sorted_calls.count * 0.95).floor]
  r[:num_publish_99]     = sorted_calls[(sorted_calls.count * 0.99).floor]
  r[:num_publish_avg]    = sorted_calls.reduce(&:+) / sorted_calls.count.to_f

  r.delete :controller_calls

  # deps percentiles
  if r[:publish_deps].count > 0
    r[:publish_deps].sort!
    index_median       = (r[:publish_deps].count / 2).floor
    index_95           = (r[:publish_deps].count * 0.95).floor
    index_99           = (r[:publish_deps].count * 0.99).floor
    r[:deps_median]    = (r[:publish_deps][index_median]).round(2)
    r[:deps_95percent] = (r[:publish_deps][index_95]).round(2)
    r[:deps_99percent] = (r[:publish_deps][index_99]).round(2)
    r[:deps_avg]       = (r[:publish_deps].reduce(&:+) / r[:publish_deps].count.to_f).round(2)
  end
  r.delete :publish_deps

  # deps percentiles
  if r[:publish_sizes].count > 0
    r[:publish_sizes].sort!
    index_median       = (r[:publish_sizes].count / 2).floor
    index_99           = (r[:publish_sizes].count * 0.99).floor
    r[:sizes_median]    = (r[:publish_sizes][index_median]).round(2)
    r[:sizes_99percent] = (r[:publish_sizes][index_99]).round(2)
    r[:sizes_avg]       = (r[:publish_sizes].reduce(&:+) / r[:publish_sizes].count.to_f).round(2)
  end
  r.delete :publish_sizes

  # publish percentiles
  if r[:num_publish] > 0
    r[:publish_durations].sort!
    index_median           = (r[:num_publish] / 2).floor
    index_95               = (r[:num_publish] * 0.95).floor
    index_99               = (r[:num_publish] * 0.99).floor
    r[:publishs_median]    = (r[:publish_durations][index_median]).round(2)
    r[:publishs_95percent] = (r[:publish_durations][index_95]).round(2)
    r[:publishs_99percent] = (r[:publish_durations][index_99]).round(2)
    r[:publishs_avg]       = (r[:publish_durations].reduce(&:+) / r[:publish_durations].count.to_f).round(2)
  end
  r.delete :publish_durations

  # controller percentiles
  r[:controller_durations].sort!
  index_median            = (r[:num_controller_calls] / 2).floor
  index_95                = (r[:num_controller_calls] * 0.95).floor
  index_99                = (r[:num_controller_calls] * 0.99).floor
  r[:durations_median]    = (r[:controller_durations][index_median]).round(2)
  r[:durations_95percent] = (r[:controller_durations][index_95]).round(2)
  r[:durations_99percent] = (r[:controller_durations][index_99]).round(2)
  r[:durations_avg]       = (r[:controller_durations].reduce(&:+) / r[:controller_durations].count.to_f).round(2)
  r.delete :controller_durations
  [controller, r]
end.sort_by { |c,r| -r[:num_controller_calls] }
]

overheads = output_normalized.values.map do |controller_data|
  controller_data[:publish_duration].to_f / controller_data[:controller_duration]
end.sort
output_normalized[:avg_overhead]    = (overheads.reduce(&:+) / overheads.count.to_f).round(2)
output_normalized[:median_overhead] = overheads[(overheads.count / 2).round].round(2)
output_normalized[:overhead_95]     = overheads[(overheads.count * 0.95).floor].round(2)
output_normalized[:overhead_99]     = overheads[(overheads.count * 0.99).floor].round(2)

puts MultiJson.dump(output_normalized, :pretty => true)
