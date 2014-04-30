#!/usr/bin/env ruby
load 'common.rb'
bootstrap(:pub)

class User
  include Promiscuous::Publisher::Model::Ephemeral

  def node
    Promiscuous::Dependency.new(id, "latest_post_id").redis_node
  end
end

$num_read_deps = ENV['NUM_READ_DEPS'].to_i
$num_users = ENV['NUM_USERS'].to_i
$num_users = 2**30 if $num_users == 0

$overhead_stat = Stats::Average.new('pub_overhead')
def publish
  loop do
    Promiscuous.context(:bench) do
      user_id = rand(1..$num_users)
      current_user = User.new(:id => user_id)
      Promiscuous::Publisher::Context.current.current_user = current_user

      $num_read_deps.times { User.new(:id => rand(1..$num_users)).read }

      post = Post.new(:author_id => user_id, :content => 'hello world')
      if post.is_a?(Promiscuous::Publisher::Model::Ephemeral)
        post.id = "#{user_id}-#{current_user.node.incr("pub:#{user_id}:latest_post_id")}"
      end

      $overhead_stat.measure { post.save }
    end
  end
end

finalize_bootstrap(:pub)
publish
