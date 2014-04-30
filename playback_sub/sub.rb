#!/usr/bin/env ruby
load 'common.rb'

bootstrap(:sub)

class User
  include Promiscuous::Subscriber
end

finalize_bootstrap(:sub)
sleep 100000
