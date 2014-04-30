#!/usr/bin/env ruby
load 'common.rb'
bootstrap(:pub)

class User
  include Promiscuous::Publisher
end

class Promiscuous::Publisher::Operation::Base
  def self.lock_options
    {
      :timeout  => 100.seconds,   # after 10 seconds, we give up so we don't queue requests
      :sleep    => 0.01.seconds, # polling every 10ms.
      :expire   => 1.minute,     # after one minute, we are considered dead
      :lock_set => Promiscuous::Key.new(:pub).join('lock_set').to_s
    }
  end
end

$num_read_deps = ENV['NUM_READ_DEPS'].to_i
$num_users = ENV['NUM_USERS'].to_i
$num_users = 2**30 if $num_users == 0

$overhead_stat = Stats::Average.new('pub_overhead')
$msg_count_bench = Stats::Counter.new('pub_msg')

def create_post(user_id)
  post = Post.new(:author_id => user_id, :content => 'hello world')
  post.id = rand(1..2**28) if ENV['DB'] == 'es'
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
