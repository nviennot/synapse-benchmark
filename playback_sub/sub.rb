#!/usr/bin/env ruby
require 'bundler'
require 'redis'
Bundler.require

$master = Redis.new(:url => 'redis://master/')

worker_index = ENV['WORKER_INDEX'].to_i
amqp_ip = nil
while amqp_ip.nil?
  amqp_ip = $master.lrange("ip:pub", worker_index, worker_index).first
  sleep 0.1
end

class Promiscuous::Subscriber::Worker::MessageSynchronizer
  remove_const :CLEANUP_INTERVAL
  CLEANUP_INTERVAL = 2
  remove_const :QUEUE_MAX_AGE
  QUEUE_MAX_AGE    = 5
end

Promiscuous.configure do |config|
  config.app = 'playback_sub'
  config.amqp_url = "amqp://guest:guest@#{amqp_ip}:5672"
  config.prefetch = 100
  config.subscriber_threads = 1
  config.redis_urls = $master.lrange("ip:redis", 0, -1).map { |r| "redis://#{r}/" }
end

Promiscuous::Config.logger.level = 1

$master.rpush("ip:sub", `hostname -i`.strip)

class Post
  include Promiscuous::Subscriber::Model::Observer
  subscribe

  after_create do
    $master.incr('sub_msg')
    sleep ENV['SUB_LATENCY'].to_f
  end
end

Promiscuous::CLI.new.subscribe
