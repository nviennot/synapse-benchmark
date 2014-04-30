#!/usr/bin/env ruby
load 'common.rb'

bootstrap(:sub)

$msg_count_bench = Stats::Counter.new('sub_msg')
class User
  include Promiscuous::Subscriber
  after_save do
$msg_count_bench.inc
sleep ENV['SUB_LATENCY'].to_f if ENV['SUB_LATENCY']

  end
end


finalize_bootstrap(:sub)
sleep 100000
