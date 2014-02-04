#!/usr/bin/env ruby
require './boot'

def clean_rabbitmq(options={})
  run <<-SCRIPT, "Purging RabbitMQ", options.merge(:tag => :pub)
    rabbitmqctl stop_app   &&
    rabbitmqctl reset      &&
    rabbitmqctl start_app
  SCRIPT
end

def update_app(options={})
  run <<-SCRIPT, "app git pull", options
    cd /srv/stream-analyzer/playback_pub
    git pull
  SCRIPT
end

def fetch_datafile(options={})
  file = options[:playback_file]
  run <<-SCRIPT, "Fetching #{file}", options.merge(:tag => :pub)
    mkdir -p /tmp/data
    cd /tmp/data
    [ -e #{file} ] || wget -q http://master/#{file}
  SCRIPT
end

def run_publisher(options={})
  fetch_datafile(options)

  run <<-SCRIPT, "Running publishers", options.merge(:tag => :pub)
    cd /srv/stream-analyzer/playback_pub

    #{"export PUB_LATENCY=#{options[:pub_latency]}" if options[:pub_latency]}
    export PLAYBACK_FILE=/tmp/data/#{options[:playback_file]}
    #{ruby_exec "./pub.rb"}
  SCRIPT
end

def run_subscriber(options={})
  run <<-SCRIPT, "Running subscribers", options.merge(:tag => :sub)
    cd /srv/stream-analyzer/playback_sub

    #{"export SUB_LATENCY=#{options[:sub_latency]}" if options[:sub_latency]}
    #{ruby_exec "./sub.rb"}
  SCRIPT
end

def register_redis_ips(options={})
  run <<-SCRIPT, "Prepping redis", options.merge(:tag => 'redis')
    redis-cli -h localhost flushdb
    redis-cli -h master rpush ip:redis `hostname -i`
  SCRIPT
end

def run_benchmark(options={})
  kill_all
  @master.flushdb

  clean_rabbitmq(options)
  register_redis_ips
  Thread.new { run_publisher(options.merge(:playback_file => "data_#{options[:num_users]}.json")) }
  Thread.new { run_subscriber(options) }

  STDERR.puts "Waiting for the publishers and subscribers to get ready..."
  loop do
    sleep 0.1
    break if @master.llen("ip:sub") == options[:num_workers]
  end

  STDERR.puts 'Starting...'
  sleep 3
  @master.set("start_pub", "1")
end

def _rate_sample
  num_samples = 20
  num_average = num_samples / 2

  num_msg_since_last = @master.getset('sub_msg', 0).to_i
  new_time, @last_time_read = @last_time_read, Time.now
  return unless new_time

  delta = @last_time_read - new_time
  rate = num_msg_since_last / delta

  @rates << rate
  STDERR.puts "Sampling: #{rate.round(1)}q/s #{@rates.size}/#{num_samples}"
  return unless @rates.size == num_samples

  avg_rate = @rates.sort_by { |x| -x }.take(num_average).reduce(:+) / num_average
  STDERR.puts "Sampling avg rate: #{avg_rate}"
  kill_all
  return avg_rate
end

def rate_sample
  @last_time_read = nil
  @rates = []
  loop do
    sleep 1
    rate = _rate_sample
    return rate if rate
  end
end

def benchmark_once(num_users, num_workers)
  run_benchmark(:num_users => num_users, :num_workers => num_workers)
  rate = rate_sample.round(1)

  result = "#{num_users} #{num_workers} #{rate}"

  STDERR.puts ">>>>>> \e[1;36m #{result}\e[0m"
  File.open("results", "a") do |f|
    f.puts result
  end
end


def benchmark_all
  num_workers = [1,3,5,10,30,50]
  num_users = [3, 30, 300, 3000]

  num_users.each do |nu|
    num_workers.each do |nw|
      benchmark_once(nu, nw)
    end
  end
end

kill_all
@master = Redis.new(:url => 'redis://master/')
# update_app

# benchmark_once(3,1)
# benchmark_once(30,1)
# benchmark_once(30,3)
# benchmark_once(30,5)
# benchmark_once(30,10)
# benchmark_once(30,30)
# benchmark_once(300,1)
# benchmark_once(3000,1)

# benchmark_all
