#!/usr/bin/env ruby
require 'bundler'
require 'redis'
Bundler.require

$master = Redis.new(:url => 'redis://master/')

$worker_index = ENV['WORKER_INDEX'].to_i
amqp_ip = nil
while amqp_ip.nil?
  amqp_ip = $master.lrange("ip:pub", $worker_index, $worker_index).first
  sleep 0.1
end

eval(JSON.parse(ENV['EVAL']).first) if ENV['EVAL']

class Promiscuous::Subscriber::Worker::MessageSynchronizer
  remove_const :CLEANUP_INTERVAL
  CLEANUP_INTERVAL = ENV['CLEANUP_INTERVAL'].to_i
  remove_const :QUEUE_MAX_AGE
  QUEUE_MAX_AGE    = ENV['QUEUE_MAX_AGE'].to_i
end

module Promiscuous::Redis
  def self.new_connection(url=nil)
    url ||= Promiscuous::Config.redis_urls
    redis = ::Redis::Distributed.new(url, :timeout => 20, :tcp_keepalive => 60)
    redis.info.each { }
    redis
  end
end

Promiscuous.configure do |config|
  config.app = 'sub'
  config.amqp_url = "amqp://guest:guest@#{amqp_ip}:5672"
  config.prefetch = ENV['PREFETCH'].to_i
  config.subscriber_threads = ENV['NUM_THREADS']
  config.hash_size = ENV['HASH_SIZE'].to_i
  config.redis_urls = $master.lrange("ip:sub_redis", 0, -1)
                        .take(ENV['NUM_REDIS'].to_i)
                        .map { |r| "redis://#{r}/" }
  config.error_notifier = proc { exit 1 }
end

Promiscuous::Config.logger.level = ENV['LOGGER_LEVEL'].to_i

$msg_count = 0

$process_msg = lambda do
  $msg_count += 1
  incr_by = 10

  if $msg_count % incr_by == 0
    $master.pipelined do
      $master.incrby("sub_msg", incr_by)
      $master.incrby("sub_msg:#{$worker_index}", incr_by)
    end
  end
  sleep ENV['SUB_LATENCY'].to_f if ENV['SUB_LATENCY']
end

class User
  include Promiscuous::Subscriber::Model::Observer
  subscribe
  after_create { $process_msg.call }
end

class Post
  include Promiscuous::Subscriber::Model::Observer
  subscribe
  after_create { $process_msg.call }
end

class Comment
  include Promiscuous::Subscriber::Model::Observer
  subscribe
  after_create { $process_msg.call }
end

Promiscuous::Subscriber::Worker.new.start
$master.rpush("ip:sub", `hostname -i`.strip)

sleep 100000
