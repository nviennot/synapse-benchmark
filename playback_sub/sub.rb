#!/usr/bin/env ruby
load 'common.rb'

bootstrap(:sub)

class User
  include Promiscuous::Subscriber::Model::Observer
  subscribe
end

class Post
  include Promiscuous::Subscriber::Model::Observer
  subscribe
end

class Comment
  include Promiscuous::Subscriber::Model::Observer
  subscribe
end

finalize_bootstrap(:sub)
sleep 100000
