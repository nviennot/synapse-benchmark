#!/usr/bin/env ruby
load 'common.rb'

amqp_ip = nil
while amqp_ip.nil?
  amqp_ip = $master.lrange("ip:pub", $worker_index, $worker_index).first
  sleep 0.1
end

bootstrap(:sub, amqp_ip)

$msg_count_bench = Stats::Counter.new('sub_msg')
$process_msg = lambda do
  $msg_count_bench.inc
  sleep ENV['SUB_LATENCY'].to_f if ENV['SUB_LATENCY']
end

class User
  include Promiscuous::Subscriber::Model::Observer
  subscribe
  after_create { $process_msg.call }
end

class Post
  include Promiscuous::Subscriber::Model::Observer
  subscribe
  after_create { $process_msg.call }
end

class Comment
  include Promiscuous::Subscriber::Model::Observer
  subscribe
  after_create { $process_msg.call }
end

Promiscuous::Subscriber::Worker.new.start
$master.rpush("ip:sub", `hostname -i`.strip)

sleep 100000
