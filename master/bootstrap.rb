#!/usr/bin/env ruby
require './boot'

def update_hosts
  run <<-SCRIPT, "Updating /etc/hosts"
    HOST=`/root/get_abricot_redis`
    sed -i "s/^.* master$/$HOST master/" /etc/hosts
  SCRIPT
end

def update_app
  run <<-SCRIPT, "app git pull"
    cd /srv/promiscuous-benchmark
    git pull
    git reset --hard origin/master
    unset BUNDLE_GEMFILE
    unset RVM_ENV
    unset BUNDLE_BIN_PATH
    unset RUBYOPT
    cd /srv/promiscuous-benchmark/playback_pub
    rvm ruby-2.0@promiscuous-benchmark do bundle install
    cd /srv/promiscuous-benchmark/playback_sub
    rvm ruby-2.0@promiscuous-benchmark do bundle install
  SCRIPT
end

kill_all
update_hosts
update_app
