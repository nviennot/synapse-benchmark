#!/usr/bin/env ruby

require 'bundler'
require 'prime'
Bundler.require

ENV['BUNDLE_GEMFILE'] = nil

ENV['SUB_LATENCY'] ||= '0.05'

Promiscuous.configure do |config|
  config.app = 'playback_master'
end

def data_file(num_users)
  "data_#{num_users}.json"
end

def generate_stream(num_users)
  file = data_file(num_users)
  return if File.exists?("../#{file}")
  `cd .. && bundle exec ./generate_stream.rb generate -u #{num_users} -n 300000 #{file}`
  exit 1 unless $?.success?
end

def run_workers(file, num_workers, tries=3)
  Promiscuous::Redis.master.flushdb

  `ps aux | grep promiscous | grep -v grep | awk '{print $2}' | xargs kill -9`

  num_workers.times do |i|
    fork do
      ENV['PLAYBACK_FILE'] = "../#{file}"
      ENV['NUM_WORKERS'] = num_workers.to_s
      ENV['WORKER_INDEX'] = i.to_s
      `promiscuous -r app.rb subscribe`
      exit 1 unless $?.success?
    end
  end

  failed = Process.waitall.any? { |pid, process| !process.success? }

  if failed
    STDERR.puts ">>>>>> \e[1;31m Failed...\e[0m"
    exit 1 if tries == 1
    STDERR.puts ">>>>>> \e[1;31m Retrying...\e[0m"
    run_workers(file, num_workers, tries-1)
  end
end

def get_rate
  Promiscuous::Redis.master.get('rate').to_f.round
end

def benchmark_once(num_users, num_workers)
  file = data_file(num_users)
  run_workers(file, num_workers)
  rate = get_rate

  result = "#{num_users} #{num_workers} #{rate}"

  STDERR.puts ">>>>>> \e[1;36m #{result}\e[0m"
  File.open("results", "a") do |f|
    f.puts result
  end
end

def benchmark_all
  num_workers = [1,3,5,10,30,50,100,300]
  num_users = [1, 10, 100, 1000]

  num_users.each do |nu|
    # Taking the first prime to avoid worker affinities when doing round robin.
    # nu = Prime.each(nu+100).select { |x| x >= nu }.first
    generate_stream(nu)

    num_workers.each do |nw|
      benchmark_once(nu, nw)
    end
  end
end

benchmark_all
