#!/usr/bin/env ruby
require 'bundler'
Bundler.require

class Promiscuous::Subscriber::Worker::MessageSynchronizer
  remove_const :CLEANUP_INTERVAL
  CLEANUP_INTERVAL = 2
  remove_const :QUEUE_MAX_AGE
  QUEUE_MAX_AGE    = 5
end

Promiscuous.configure do |config|
  config.app = 'playback_sub'
  config.amqp_url = 'amqp://guest:guest@localhost:5672'
  config.prefetch = 100
  config.subscriber_threads = 1
  config.redis_urls = ["redis://localhost"]
end

Promiscuous::Config.logger.level = 1

class Post
  include Promiscuous::Subscriber::Model::Observer
  subscribe

  if ENV['SUB_LATENCY']
    after_create do
      sleep ENV['SUB_LATENCY'].to_f
    end
  end
end

Promiscuous::CLI.new.subscribe
