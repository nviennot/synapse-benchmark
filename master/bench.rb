#!/usr/bin/env ruby
require './boot'

class Deadlock < RuntimeError; end

def update_app
  run <<-SCRIPT, "app git pull"
    cd /srv/promiscuous-benchmark/playback_pub &&
    git pull
  SCRIPT
end

def register_redis_ips
  run <<-SCRIPT, "Prepping redis (sub)", :tag => :sub_redis
    redis-cli -h localhost flushdb &&
    redis-cli -h master rpush ip:sub_redis `hostname -i`
  SCRIPT

  run <<-SCRIPT, "Prepping redis (pub)", :tag => :pub_redis
    redis-cli -h localhost flushdb &&
    redis-cli -h master rpush ip:pub_redis `hostname -i`
  SCRIPT
end

def clean_rabbitmq
  run <<-SCRIPT, "Purging RabbitMQ", :tag => :pub
    sudo rabbitmqctl stop_app   &&
    sudo rabbitmqctl reset      &&
    sudo rabbitmqctl start_app  &&
    sleep 1
  SCRIPT
end

def run_publisher(options={})
  run <<-SCRIPT, "Running publishers", options.merge(:tag => :pub)
    cd /srv/promiscuous-benchmark/playback_pub

    export MAX_NUM_FRIENDS=#{options[:max_num_friends]}
    export COEFF_NUM_FRIENDS=#{options[:coeff_num_friends]}
    export NUM_USERS=#{options[:num_users]}
    export HASH_SIZE=#{options[:hash_size]}
    export LOGGER_LEVEL=1

    #{"export NUM_REDIS=#{options[:num_pub_redis]}" if options[:num_pub_redis]}
    #{"export PUB_LATENCY=#{options[:pub_latency]}" if options[:pub_latency]}
    #{ruby_exec "./pub.rb"}
  SCRIPT
end

def run_subscriber(options={})
  run <<-SCRIPT, "Running subscribers", options.merge(:tag => :sub)
    cd /srv/promiscuous-benchmark/playback_sub

    export CLEANUP_INTERVAL=#{options[:cleanup_interval]}
    export QUEUE_MAX_AGE=#{options[:queue_max_age]}
    export PREFETCH=#{options[:prefetch]}
    export HASH_SIZE=#{options[:hash_size]}
    export LOGGER_LEVEL=1

    #{"export NUM_REDIS=#{options[:num_sub_redis]}" if options[:num_sub_redis]}
    #{"export SUB_LATENCY=#{options[:sub_latency]}" if options[:sub_latency]}
    #{ruby_exec "./sub.rb"}
  SCRIPT
end

def run_benchmark(options={})
  kill_all
  @master.flushdb

  @abricot.multi do
    clean_rabbitmq
    register_redis_ips
  end

  jobs = @abricot.multi :async => true do
    run_publisher(options)
    run_subscriber(options)
  end

  start = Time.now
  loop do
    sleep 0.1
    jobs.check_for_failures
    break if @master.llen("ip:sub") == options[:num_workers]
    if Time.now - start > 30
      jobs.kill
      raise Deadlock
    end
  end

  STDERR.puts 'Starting...'
  @master.set("start_pub", "1")
  jobs
end

class Rate
  attr_accessor :key
  def initialize(master, key)
    @master = master
    @key = key
    @rates = []

    @num_samples = 60
    @num_dropped = @num_samples / 3
  end

  def sample
    num_msg_since_last = @master.getset(@key, 0).to_i
    new_time, @last_time_read = @last_time_read, Time.now
    return unless new_time

    delta = @last_time_read - new_time
    rate = num_msg_since_last / delta

    if @rates.size >= 5 && @rates[-5..-1].all? { |r| r.zero? }
      raise Deadlock
    end

    @rates << rate
    STDERR.puts "Sampling of #{@key}: #{rate.round(1)}q/s #{@rates.size}/#{@num_samples}"
  end

  def rate
    return unless @rates.size == @num_samples

    sampled_rates = @rates.sort_by { |x| -x }.to_a[@num_dropped/2 ... -@num_dropped/2]
    avg_rate = sampled_rates.reduce(:+) / sampled_rates.size.to_f

    STDERR.puts "Sampling avg rate of #{@key}: #{avg_rate}"
    return avg_rate
  end
end

def rate_sample(jobs, options={})
  sub_rate = Rate.new(@master, 'sub_msg')
  pub_rate = Rate.new(@master, 'pub_msg')

  # sub_workers_rate = options[:num_workers].times.map { |i| Rate.new(@master, "sub_msg:#{i}") }

  loop do
    sleep 1

    jobs.check_for_failures

    puts
    pub_rate.sample
    sub_rate.sample

    # sub_workers_rate.each(&:sample)

    pr = pr = pub_rate.rate
    sr = sr = sub_rate.rate

    return sr if sr
  end
end

def benchmark_once(options={})
  tries = 3

  options = options.dup
  if options[:num_redis]
    options[:num_sub_redis] = options[:num_redis]
    options[:num_pub_redis] = options[:num_redis]
  end

  begin
    tries -= 1
    jobs = run_benchmark(options)
    rate = rate_sample(jobs, options).round(1)
    jobs.kill

    result = "#{options[:num_users]} #{options[:num_workers]} #{rate}"

    STDERR.puts ">>>>>> \e[1;36m #{result}\e[0m"
    File.open("results", "a") do |f|
      f.puts result
    end
  rescue Deadlock
    jobs.kill if jobs
    STDERR.puts ">>>>>> \e[1;31m Deadlocked :(\e[0m"
    if tries > 0
      STDERR.puts ">>>>>> \e[1;31m Retrying...\e[0m"
      retry
    end
  end
end

def _benchmark(options={})
  key, values = options.select { |k,v| v.is_a?(Array) }.first
  if values
    values.each { |v| _benchmark(options.merge(key => v)) }
  else
    benchmark_once(options)
  end
end

def benchmark(options={})
  File.open("results", "a") do |f|
    f.puts ""
    f.puts "#" + "-" * 80
    options.each do |k,v|
      f.puts "# :#{k} => #{v}"
    end
  end

  _benchmark(options)
end

begin
  kill_all
  @master = Redis.new(:url => 'redis://master/')
  # benchmark_all
  # update_app

  options = {
    #:pub_latency => "0.002",
    :num_users => [100, 1000, 10000],
    :num_workers => [1,3,10, 30, 64],
    :num_pub_redis => 10,
    :num_sub_redis => 10,

    :cleanup_interval => 10,
    :queue_max_age => 50,
    :hash_size => 0,
    :prefetch => 100,

    :max_num_friends => 500,
    :coeff_num_friends => 0.8,
  }

  benchmark(options)
rescue Exception => e
  STDERR.puts "-" * 80
  STDERR.puts e.message
  STDERR.puts e.backtrace.join("\n")
  STDERR.puts
  STDERR.puts
end
