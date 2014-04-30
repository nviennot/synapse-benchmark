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
  include Promiscuous::Publisher

  def node
    Promiscuous::Dependency.new(id, "latest_post_id").redis_node
  end
end

$overhead_stat = Stats::Average.new('pub_overhead')
$msg_count_bench = Stats::Counter.new('pub_msg')

def create_post(user_id)
  current_user = User.new(:id => user_id)
  Promiscuous::Publisher::Context.current.current_user = current_user

  post = Post.new(:author_id => user_id, :content => 'hello world')
  if post.is_a?(Promiscuous::Publisher::Model::Ephemeral)
    post.id = "#{user_id}0#{current_user.node.incr("pub:#{user_id}:latest_post_id")}"
  end

  $overhead_stat.measure { post.save }
  $msg_count_bench.inc

  unless post.is_a?(Promiscuous::Publisher::Model::Ephemeral)
    current_user.node.set("pub:#{user_id}:latest_post_id", post.id)
  end
end

def create_comment(user_id)
  friend_id = @users[user_id].sample
  return create_post(user_id) unless friend_id

  friend = User.new(:id => friend_id)
  friend.read

  current_user = User.new(:id => user_id)
  Promiscuous::Publisher::Context.current.current_user = current_user

  post_id = friend.node.get("pub:#{friend_id}:latest_post_id")
  post = Post.new(:id => post_id)

  op = Promiscuous::Publisher::Operation::NonPersistent
         .new(:instances => [post], :operation => :read)
  Promiscuous::Publisher::Context.current.read_operations << op

  comment = Comment.new(:author_id => user_id, :post_id => post_id, :content => 'hello world')

  if comment.is_a?(Promiscuous::Publisher::Model::Ephemeral)
    comment.id = rand(1..2**30)
  end

  $overhead_stat.measure { comment.save }
  $msg_count_bench.inc
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
