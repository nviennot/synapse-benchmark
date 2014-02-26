#!/usr/bin/env ruby
require './boot'

class Deadlock < RuntimeError; end

def update_app
  run <<-SCRIPT, "app git pull"
    cd /srv/promiscuous-benchmark/playback_pub &&
    git pull https://github.com/nviennot/promiscuous-benchmark.git master:master
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
    #{"export EVAL='#{[options[:pub_eval]].to_json}'" if options[:pub_eval]}
    #{"export NUM_REDIS=#{options[:num_pub_redis]}" if options[:num_pub_redis]}
    #{"export PUB_LATENCY=#{options[:pub_latency]}" if options[:pub_latency]}
    #{"export NUM_READ_DEPS=#{options[:num_read_deps]-1}" if options[:num_read_deps]}
    #{ruby_exec(options[:num_read_deps] ? "./pub_dep.rb" : "./pub.rb")}
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
    export NUM_THREADS=1
    #{"export EVAL='#{[options[:sub_eval]].to_json}'" if options[:sub_eval]}
    #{"export NUM_REDIS=#{options[:num_sub_redis]}" if options[:num_sub_redis]}
    #{"export SUB_LATENCY=#{options[:sub_latency]}" if options[:sub_latency]}
    #{ruby_exec "./sub.rb"}
  SCRIPT
end

def run_benchmark(options={})
  STDERR.puts "Launching with #{options}"

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

module Stats
  class Base
    attr_accessor :key, :samples
    def initialize(master, key)
      @master = master
      @key = key
      @samples = []
      @num_samples = 60
    end

    def sample
      return if finished?
      s = read_sample
      return unless s
      @samples << s
      STDERR.puts "[#{@samples.size}/#{@num_samples}] Sampling of #{@key}: \e[1;37m#{s.round(1)}\e[0m#{unit}"
    end

    def finished?
      @samples.size == @num_samples
    end

    def average
      return unless finished?

      # We remove 1/3 of the data
      drop_window = @samples.size / 3

      clean_samples = @samples.sort_by { |x| -x }.to_a[drop_window/2 ... -drop_window/2]
      avg = clean_samples.reduce(:+) / clean_samples.size.to_f

      STDERR.puts "Average sampling of #{@key}: \e[1;36m#{avg.round(1)}\e[0m#{unit}"
      avg
    end
  end

  class Counter < Base
    def read_sample
      num_msg_since_last = @master.getset(@key, 0).to_i
      new_time, @last_time_read = @last_time_read, Time.now
      return unless new_time

      delta = @last_time_read - new_time
      num_msg_since_last / delta
    end

    def unit
      "msg/s"
    end
  end

  class Average < Base
    def read_sample
      t, s = @master.multi do
        @master.getset("#{@key}:total", 0)
        @master.getset("#{@key}:samples", 0)
      end

      unless @sampled_once
        @sampled_once = true
        return
      end

      t.to_f / (s.to_f * 100)
    end

    def unit
      "ms"
    end
  end
end

def measure_stats(jobs, options={})
  sub_rate = Stats::Counter.new(@master, 'sub_msg')
  pub_rate = Stats::Counter.new(@master, 'pub_msg')
  pub_overhead = Stats::Average.new(@master, 'pub_overhead')

  loop do
    sleep 1

    jobs.check_for_failures

    puts
    pub_overhead.sample
    pub_rate.sample
    sub_rate.sample

    if sub_rate.samples.size >= 5 && sub_rate.samples[-5..-1].all? { |r| r.zero? }
      raise Deadlock
    end

    if sub_rate.finished?
      STDERR.puts "-" * 80
      return sub_rate.average, pub_overhead.average
    end
  end
end

def benchmark_once(variables, options={})
  num_tries = 3
  tries = num_tries

  options = options.dup
  if options[:num_redis]
    options[:num_sub_redis] = options[:num_redis]
    options[:num_pub_redis] = options[:num_redis]
  end

  begin
    num_retries = num_tries - tries

    tries -= 1
    jobs = run_benchmark(options)
    rate, pub_overhead = measure_stats(jobs, options)
    rate = rate.round(1)
    pub_overhead = pub_overhead.round(2)
    puts
    puts
    jobs.kill

    pub_overhead = pub_overhead

    result = (variables.map { |v| options[v] } + [rate, pub_overhead]).join(" ")
    result += " # retried #{num_retries} time" if num_retries > 0

    STDERR.puts ">>>>>> \e[1;36m #{result}\e[0m"
    File.open("results", "a") do |f|
      f.puts result
    end
  rescue Deadlock, Abricot::Master::JobFailure => e
    jobs.kill if jobs
    STDERR.puts ">>>>>> \e[1;31m #{e.class} :(\e[0m"
    STDERR.puts e
    if tries > 0
      STDERR.puts ">>>>>> \e[1;31m Retrying...\e[0m"
      retry
    end
  end
end

def _benchmark(variables, options={})
  key, values = options.select { |k,v| v.is_a?(Array) }.first
  if values
    values.each { |v| _benchmark(variables + [key], options.merge(key => v)) }
  else
    benchmark_once(variables, options)
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

  _benchmark([], options)
end

begin
  kill_all
  @master = Redis.new(:url => 'redis://master/')
  # benchmark_all
  # update_app

  options = {
    :num_users => 1000,
    :num_read_deps => [1,10,100,100],
    :num_workers => [1,2,5,10,20,50,100],
    :hash_size => 0,
    :num_redis => 15,
    # :num_workers => 100,

    #:pub_latency => "0.002",
    #:sub_latency => "0.002",
    :cleanup_interval => 10,
    :queue_max_age => 50,
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
