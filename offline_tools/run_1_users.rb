#!/usr/bin/env ruby

require 'net/http'
require 'json'
require 'pry'

def login(http, username, password)
  r = http.post('/users/sign_in', {:user => {:username => username, :password => password}}.to_json,
                                  {"Content-Type" => "application/json"})

  raise "cannot login" if r.code.to_i != 302

  cookies = Hash[r.header.each.select { |k,v| k == 'set-cookie' }]['set-cookie']
  cookies.sub(/;[^;]*$/, ';')
end

def create_post(http, user, aspect_ids, content)
  r = http.post('/status_messages', {:aspect_ids => aspect_ids, :status_message => { :text => content } }.to_json,
                                    {"Accept" => "application/json", "Content-Type" => "application/json", "Cookie" => user})
  raise "cannot create post" if r.code[0] != '2'
end

http = Net::HTTP.new('localhost', 3000)
eve = login(http, 'joe', 'evankorth')
sleep 1
`rm /tmp/instrumentation.log`
create_post(http, eve, 'all_aspects', "hello world from eve")
