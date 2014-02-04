#!/usr/bin/env ruby
require 'bundler'
Bundler.require

$current_worker = ENV['WORKER_INDEX'].to_i
$master_worker = $current_worker == 0

Promiscuous.configure do |config|
  config.app = 'playback_pub'
  config.amqp_url = 'amqp://guest:guest@localhost:5672'
  config.hash_size = 0
  config.redis_urls = ["redis://localhost"]
end

Promiscuous::Config.logger.level = 1

$message_count = 0

def wait_for_workers
  n = ENV['NUM_WORKERS'].to_i
  return if n.zero?
  Promiscuous::Redis.master.incr("num_workers")

  loop do
    return if Promiscuous::Redis.master.get("num_workers").to_i == n
    sleep 0.2
  end
end

# wait_for_workers

class Promiscuous::Publisher::Operation::Ephemeral
  def execute
    super do
      Promiscuous::Redis.master.incr('num_msgs')
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

puts "running..."
STDERR.puts "(e) running..."

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
playback
