#!/usr/bin/env ruby
require './boot'

raise unless ENV['MASTER_IP']
raise unless ENV['ZONE']

counts = 0
@master = Redis.new(:url => 'redis://master/')
@master.flushdb
@master.pipelined do
  ARGV.each_slice(2).each do |count, role|
    counts += count.to_i
    count.to_i.times.each { @master.rpush('roles', role) }
  end
end

run <<-SCRIPT, "Updating launch.sh", :tag => ENV['ZONE'], :num_workers => counts
  HOST=#{ENV['MASTER_IP']}
  echo -e "#!/bin/bash\\nabricot listen --redis redis://$HOST/2 --tags #{ENV['ZONE']},`redis-cli -h $HOST lpop roles`" > /srv/abricot/launch.sh
  service abricot restart
SCRIPT

# run <<-SCRIPT, "Updating launch.sh"
  # HOST=#{ENV['MASTER_IP']}
  # sleep $[($RANDOM%120)+1]
  # echo -e "#!/bin/bash\\nabricot listen --redis redis://10.146.216.252/2 --tags `/root/get_ec2_tags`" > /srv/abricot/launch.sh
  # service abricot restart
# SCRIPT
