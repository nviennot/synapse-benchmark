#!/usr/bin/env ruby
require './boot'

def update_hosts
  ip="10.179.139.38"
  run <<-SCRIPT, "Updating /etc/hosts"
    # HOST=`/root/get_abricot_redis`
    sed -i "s/^.* master$/#{ip} master/" /etc/hosts
  SCRIPT
end

def update_app
  run <<-SCRIPT, "Updating application"
    cd /srv/promiscuous-benchmark &&
    git fetch https://github.com/nviennot/promiscuous-benchmark.git
    git reset --hard FETCH_HEAD
    unset BUNDLE_GEMFILE &&
    unset RVM_ENV &&
    unset BUNDLE_BIN_PATH &&
    unset RUBYOPT &&
    cd /srv/promiscuous-benchmark/playback_pub &&
    rvm ruby-2.0@promiscuous-benchmark do bundle install &&
    cd /srv/promiscuous-benchmark/playback_sub &&
    rvm ruby-2.0@promiscuous-benchmark do bundle install
  SCRIPT
end

# kill_all
update_hosts
update_app
