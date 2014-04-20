#!/usr/bin/env ruby

require 'net/http'
require 'json'
require 'pry'
require 'redis'

module Promiscuous; end
load '~/promiscuous/lib/promiscuous/latch.rb'
module Promiscuous::Latch
  def latch_name
    "diaspora_email:sub_latch"
  end

  def redis_node
    @redis ||= Redis.new(:url => 'redis://localhost:7778/')
  end
end

def login(http, username, password)
  r = http.post('/users/sign_in', {:user => {:username => username, :password => password}}.to_json,
                                  {"Content-Type" => "application/json"})

  raise "cannot login" if r.code.to_i != 302

  cookies = Hash[r.header.each.select { |k,v| k == 'set-cookie' }]['set-cookie']
  cookies.sub(/;[^;]*$/, ';')
end

def get_aspects(http, user)
  r = http.get('/aspects_list', {"Accept" => "application/json", "Content-Type" => "application/json", "Cookie" => user})
  raise "cannot list aspects" if r.code[0] != '2'
  as = JSON.parse(r.body)
  Hash[as.map { |a| a['aspect'] }.map { |a| [a['name'], a] }]
end

def delete_aspect(http, user, aspect_id)
  http.delete("/aspects/#{aspect_id}", {"Accept" => "application/json", "Content-Type" => "application/json", "Cookie" => user})
end

def create_aspect(http, user, aspect)
  r = http.post('/aspects', {:aspect => {:name => aspect}}.to_json,
                        {"Accept" => "application/json", "Content-Type" => "application/json", "Cookie" => user})
  raise "cannot list aspects" if r.code[0] != '2'
  JSON.parse(r.body)['aspect']
end

def add_friend(http, user, aspect_id, person_id)
  r = http.post('/aspect_memberships', {:aspect_id => aspect_id, :person_id => person_id}.to_json,
                                    {"Accept" => "application/json", "Content-Type" => "application/json", "Cookie" => user})
  raise "cannot add friend" if r.code[0] != '2'
  JSON.parse(r.body)
end

def remove_friend(http, user, friendship_id)
  r = http.delete("/aspect_memberships/#{friendship_id}", 
                  {"Accept" => "application/json", "Content-Type" => "application/json", "Cookie" => user})
  raise "cannot remove friend" if r.code[0] != '2'
  JSON.parse(r.body)
end

def create_fresh_aspect(http, user, aspect_name)
  user_aspects = get_aspects(http, user)
  delete_aspect(http, user, user_aspects['friends']['id']) if user_aspects['friends']
  create_aspect(http, user, 'friends')
end

def create_post(http, user, aspect_ids, content)
  r = http.post('/status_messages', {:aspect_ids => aspect_ids, :status_message => { :text => content } }.to_json,
                                    {"Accept" => "application/json", "Content-Type" => "application/json", "Cookie" => user})
  raise "cannot create post" if r.code[0] != '2'
end

Promiscuous::Latch.disable

$alice_id = 1
http = Net::HTTP.new('localhost', 3000)

eve = login(http, 'joe', 'evankorth')
bob = login(http, 'vic', 'evankorth')

eve_friend_aspect = create_fresh_aspect(http, eve, 'friends')
bob_friend_aspect = create_fresh_aspect(http, bob, 'friends')

eve_friendship = add_friend(http, eve, eve_friend_aspect['id'], $alice_id)
bob_friendship = add_friend(http, bob, bob_friend_aspect['id'], $alice_id)

sleep 1
Promiscuous::Latch.enable
`rm /tmp/instrumentation.log`

remove_friend(http, eve, eve_friendship['id'])
remove_friend(http, bob, bob_friendship['id'])

create_post(http, eve, eve_friend_aspect['id'], "hello world from eve")
create_post(http, bob, bob_friend_aspect['id'], "hello world from bob")

sleep 1
Promiscuous::Latch.release(10)
Promiscuous::Latch.disable
