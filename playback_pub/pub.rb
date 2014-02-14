#!/usr/bin/env ruby
require 'bundler'
require 'redis'
Bundler.require

$master = Redis.new(:url => 'redis://master/')

$master.rpush("ip:pub", `hostname -i`.strip)

$worker_index = ENV['WORKER_INDEX'].to_i

Promiscuous.configure do |config|
  config.app = 'playback_pub'
  config.amqp_url = 'amqp://guest:guest@localhost:5672'
  config.hash_size = ENV['HASH_SIZE'].to_i
  config.redis_urls = $master.lrange("ip:pub_redis", 0, -1)
                        .take(ENV['NUM_REDIS'].to_i)
                        .map { |r| "redis://#{r}/" }
end

module Promiscuous::Redis
  def self.new_connection(url=nil)
    url ||= Promiscuous::Config.redis_urls
    ::Redis::Distributed.new(url, :timeout => 20, :tcp_keepalive => 60)
  end
end

Promiscuous::Config.logger.level = 1

class Promiscuous::Publisher::Operation::Ephemeral
  def execute
    super do
      $master.pipelined do
        $master.incr("pub_msg")
        $master.incr("pub_msg:#{$worker_index}")
      end

      sleep ENV['PUB_LATENCY'].to_f if ENV['PUB_LATENCY']
    end
  end
end

module Promiscuous::Publisher::Model::Ephemeral
  def read
    op = Promiscuous::Publisher::Operation::NonPersistent
      .new(:instances => [self], :operation => :read)
    Promiscuous::Publisher::Context.current.read_operations << op
  end
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

  @users = friends
end
generate_users

if @users.empty?
  puts "no users..."
  exit
end

#-------------------------------------------------------------

class User
  include Promiscuous::Publisher::Model::Ephemeral
end

class Post
  include Promiscuous::Publisher::Model::Ephemeral
  publish :user_id
  # track_dependencies_of :user_id
end

class Comment
  include Promiscuous::Publisher::Model::Ephemeral
  publish :user_id
  publish :post_id
end

def create_post(user_id)
  current_user = User.new(:id => user_id)
  current_user.read

  pid = $master.incr("pub:#{user_id}:latest_post_id")
  post_id = "#{user_id}_#{pid}"
  post = Post.new(:id => post_id, :user_id => user_id)
  post.save
end

def create_comment(user_id)
  friend_id = @users[user_id].sample
  return create_post(user_id) unless friend_id

  friend = User.new(:id => friend_id)
  friend.read

  current_user = User.new(:id => user_id)
  current_user.read

  pid = $master.get("pub:#{friend_id}:latest_post_id").to_i
  post_id = "#{friend_id}_#{pid}"
  post = Post.new(:id => post_id, :user_id => friend_id)
  post.read

  comment = Comment.new(:id => "#{post_id}_#{rand(1..2**4)}",
                        :user_id => friend_id,
                        :post_id => post_id)
  comment.save
end

def publish
  loop do
    Promiscuous.context(:bench) do
      user_id = @users.keys.sample
      if rand(1..3) == 1
        create_post(user_id)
      else
        create_comment(user_id)
      end
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
