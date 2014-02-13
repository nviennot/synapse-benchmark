#!/usr/bin/env ruby
require 'bundler'
require 'redis'
Bundler.require

$master = Redis.new(:url => 'redis://master/')

$master.rpush("ip:pub", `hostname -i`.strip)

Promiscuous.configure do |config|
  config.app = 'playback_pub'
  config.amqp_url = 'amqp://guest:guest@localhost:5672'
  config.hash_size = 0
  config.redis_urls = $master.lrange("ip:pub_redis", 0, -1)
                        .take(ENV['NUM_REDIS'].to_i)
                        .map { |r| "redis://#{r}/" }
end

Promiscuous::Config.logger.level = 1

class Promiscuous::Publisher::Operation::Ephemeral
  def execute
    super do
      $master.incr('pub_msg')
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

def generate_users
  friend_distribution = Zipfian.new(ENV['MAX_NUM_FRIENDS'].to_i, ENV['COEFF_NUM_FRIENDS'].to_f)

  worker_index = ENV['WORKER_INDEX'].to_i
  num_workers = ENV['NUM_WORKERS'].to_i
  num_users = ENV['NUM_USERS'].to_i

  start_idx = ((num_users.to_f / num_workers) * worker_index).to_i
  end_idx   = ((num_users.to_f / num_workers) * (worker_index + 1)).to_i

  users = (start_idx...end_idx).to_a
  all_users = (0...num_users).to_a
  friends = {}

  users.each do |user_id|
    friends[user_id] = all_users.sample(friend_distribution.sample) - [user_id]
  end

  $users = friends
  $publish_zipf = Hash[friends.map { |user_id, all_friends| [user_id, Zipfian.new(all_friends.size, ENV['COEFF_FRIEND_ACTIVITY'].to_f)] }]
end
generate_users

def publish
  loop do
    Promiscuous.context(:bench) do
      user_id, all_friends = $users.to_a.sample
      friends = all_friends.sample($publish_zipf[user_id].sample)

      post_id, friends_post_ids = $master.pipelined do
        $master.incr("pub:#{user_id}:latest_post_id")
        $master.mget(friends.map { |friend_id| "pub:#{friend_id}:latest_post_id"})
      end

      p = Post.new
      p.id = "#{user_id}_#{post_id}"
      p.user_id = user_id

      c = Promiscuous::Publisher::Context.current
      c.extra_dependencies = friends.zip(friends_post_ids).map do |friend_id, fpost_id|
        Promiscuous::Dependency.parse("posts/id/#{friend_id}_#{fpost_id}", :type => :read)
      end

      p.save
    end
  end
end

def wait_for_start_signal
  loop do
    return if $master.get("start_pub")
    sleep 0.1
  end
end
wait_for_start_signal

publish
