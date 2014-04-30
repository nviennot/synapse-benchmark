#!/usr/bin/env ruby
load 'common.rb'
bootstrap(:pub)

class User
  include Promiscuous::Publisher
end

$num_read_deps = ENV['NUM_READ_DEPS'].to_i
$num_users = ENV['NUM_USERS'].to_i
$num_users = 2**30 if $num_users == 0

$overhead_stat = Stats::Average.new('pub_overhead')
$msg_count_bench = Stats::Counter.new('pub_msg')

def create_post(user_id)
  post = Post.new(:id => rand(2**28), :author_id => user_id, :content => 'hello world')
  $num_read_deps.times { User.new(:id => rand(1..$num_users)).read }
  $overhead_stat.measure { post.save }
  $msg_count_bench.inc
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
