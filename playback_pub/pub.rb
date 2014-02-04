#!/usr/bin/env ruby
require 'bundler'
require 'redis'
Bundler.require

master = Redis.new(:url => 'redis://master/')

master.rpush("ip:pub", `hostname -i`)

Promiscuous.configure do |config|
  config.app = 'playback_pub'
  config.amqp_url = 'amqp://guest:guest@localhost:5672'
  config.hash_size = 0
  config.redis_urls = master.lrange("ip:redis", 0, -1)
end

Promiscuous::Config.logger.level = 1

class Promiscuous::Publisher::Operation::Ephemeral
  def execute
    super do
      master.incr('pub_msg')
      sleep ENV['PUB_LATENCY'].to_f
    end
  end
end

class Post
  include Promiscuous::Publisher::Model::Ephemeral
  attr_accessor :user_id
  publish :user_id
  track_dependencies_of :user_id
end

def playback
  file = File.open(ENV['PLAYBACK_FILE'], 'r')
  worker_index = ENV['WORKER_INDEX'].to_i
  num_workers = ENV['NUM_WORKERS'].to_i

  file.each_with_index do |line, i|
    if num_workers > 0
      next if ((i+worker_index) % num_workers) != 0
    end

    Promiscuous.context(:bench) do
      json = MultiJson.load(line)
      deps = json['dependencies']['write']

      # c = Promiscuous::Context.current
      p = Post.new
      p.id = deps[1].split(':').first.split('_').last
      p.user_id = deps[0].split(':').first.split('_').last
      p.save
    end
  end
end

def wait_for_start_signal
  loop do
    return if master.get("start_pub")
    sleep 0.1
  end
end
wait_for_start_signal

playback
