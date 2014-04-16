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
      end
      slice
    rescue Exception => e
      STDERR.puts "WARN: parse error"
    end
  end.compact
end

slices = parse_file(ARGV[0])
slices.sort_by!(&:start)

output = slices.map do |slice|
  if slice.type == :publish && slice.payload
    [slice, slice.payload['context'], slice.payload['real_deps']['read']] rescue nil
  elsif slice.type == :app_controller && slice.read_deps
    [slice, slice.desc, slice.read_deps]
  end
end.compact.reduce({}) do |results, (slice, controller, read_deps)|
  if controller =~ /^[^ ]+\/+[^ ]+$/
    results[controller] ||= {:read_deps => 0,
                             :read_deps_with_tracking => 0,
                             :num_publish => 0,
                             :num_controller_calls => 0,
                             :read_only_deps => 0,
                             :publish_duration => 0.0,
                             :controller_duration => 0.0}

    r = results[controller]

    if slice.type == :publish
      r[:read_deps] += read_deps.flatten.uniq.size
      r[:read_deps_with_tracking] += read_deps.reject(&:empty?).uniq.size
      r[:num_publish] += 1
      r[:publish_duration] += slice.duration
    end

    if slice.type == :app_controller
      r[:num_controller_calls] += 1
      r[:read_only_deps] += read_deps.flatten.uniq.size
      r[:controller_duration] += slice.duration
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
  [controller, r]
end.sort_by { |c,r| -r[:num_controller_calls] }
]

puts MultiJson.dump(output_normalized, :pretty => true)
