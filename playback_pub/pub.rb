#!/usr/bin/env ruby
load 'common.rb'
bootstrap(:pub)

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

  def node
    Promiscuous::Dependency.new(id, "latest_post_id").redis_node
  end
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

$overhead_stat = Stats::Average.new('pub_overhead')

def create_post(user_id)
  current_user = User.new(:id => user_id)
  current_user.read


  pid = current_user.node.incr("pub:#{user_id}:latest_post_id")
  post_id = "#{user_id}_#{pid}"
  post = Post.new(:id => post_id, :user_id => user_id)
  $overhead_stat.measure { post.save }
end

def create_comment(user_id)
  friend_id = @users[user_id].sample
  return create_post(user_id) unless friend_id

  friend = User.new(:id => friend_id)
  friend.read

  current_user = User.new(:id => user_id)
  current_user.read

  pid = friend.node.get("pub:#{friend_id}:latest_post_id").to_i
  post_id = "#{friend_id}_#{pid}"
  post = Post.new(:id => post_id, :user_id => friend_id)
  post.read

  comment = Comment.new(:id => "#{post_id}_#{rand(1..2**4)}",
                        :user_id => friend_id,
                        :post_id => post_id)
  $overhead_stat.measure { comment.save }
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

finalize_bootstrap(:pub)
publish
