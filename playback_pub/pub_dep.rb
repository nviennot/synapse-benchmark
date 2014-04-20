#!/usr/bin/env ruby
load 'common.rb'
bootstrap(:pub)

class User
  include Promiscuous::Publisher::Model::Ephemeral
end

$num_read_deps = ENV['NUM_READ_DEPS'].to_i
$num_users = ENV['NUM_USERS'].to_i
$num_users = 2**30 if $num_users == 0

$overhead_stat = Stats::Average.new('pub_overhead')
def publish
  loop do
    Promiscuous.context(:bench) do
      current_user = User.new(:id => rand(1..$num_users))
      $num_read_deps.times { User.new(:id => rand(1..$num_users)).read }
      $overhead_stat.measure { current_user.save }
    end
  end
end

finalize_bootstrap(:pub)
publish
