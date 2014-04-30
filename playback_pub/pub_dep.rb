#!/usr/bin/env ruby
load 'common.rb'
bootstrap(:pub)

$num_read_deps = ENV['NUM_READ_DEPS'].to_i
$num_users = ENV['NUM_USERS'].to_i
$num_users = 2**30 if $num_users == 0


$overhead_stat = Stats::Average.new('pub_overhead')
$msg_count_bench = Stats::Counter.new('pub_msg')

def create_post(user_id)
  current_user = User.new(:id => user_id)
  Promiscuous::Publisher::Context.current.current_user = current_user

  post = Post.new(:author_id => user_id, :content => 'hello world')
  if post.is_a?(Promiscuous::Publisher::Model::Ephemeral)
    post.id = "#{user_id}0#{current_user.node.incr("pub:#{user_id}:latest_post_id")}"
    post.id = 1
  end

  $overhead_stat.measure { post.save }
  $msg_count_bench.inc

  unless post.is_a?(Promiscuous::Publisher::Model::Ephemeral)
    current_user.node.set("pub:#{user_id}:latest_post_id", post.id)
  end
end

def publish
  loop do
    Promiscuous.context(:bench) do
      create_post(rand(1..$num_users))
    end
  end
end

finalize_bootstrap(:pub)
publish
