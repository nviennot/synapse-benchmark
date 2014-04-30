#!/usr/bin/env ruby
require './boot'

raise unless ENV['MASTER_IP']

def update_hosts
  run <<-SCRIPT, "Updating /etc/hosts"
    # HOST=`/root/get_abricot_redis`
    HOST=#{ENV['MASTER_IP']}
    sed -i "s/^.* master$/$HOST master/" /etc/hosts
  SCRIPT
end

def update_app
  run <<-SCRIPT, "Updating application"
    cd /srv/promiscuous-benchmark &&
    git fetch &&
    git reset --hard FETCH_HEAD &&
    unset BUNDLE_GEMFILE &&
    unset RVM_ENV &&
    unset BUNDLE_BIN_PATH &&
    unset RUBYOPT &&
    cd /srv/promiscuous-benchmark/playback_pub &&
    rvm ruby-2.1.1 do bundle install
  SCRIPT
end

# kill_all
update_hosts
# update_app
