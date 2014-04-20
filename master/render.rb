#!/usr/bin/env ruby

rate = {}
overhead = {}

File.open(ARGV[0] || 'results').each do |line|
  line = line.gsub(/#.*$/, '').gsub(/[\t ]+/, ' ').strip
  next if line.empty?

  items = line.chomp.gsub(/[\t ]+/, ' ').split(' ')
  users = items[0]
  workers = items[1]
  r = items[2]
  o = items[3]

  rate[workers] ||= {}
  rate[workers][users] = r

  overhead[workers] ||= {}
  overhead[workers][users] = o
end

users = rate.values.map(&:keys).flatten.uniq

File.open('throughput-vs-workers.dat', 'w') do |f|
  rate.each do |workers, ur|
    f.puts([workers, *users.map { |u| ur[u] }].join(' '))
  end
end

`gnuplot throughput-vs-workers.plot`
`gnuplot throughput-vs-workers-saturate.plot`

File.open('overhead-vs-deps.dat', 'w') do |f|
  overhead.each do |workers, ur|
    f.puts([workers, *users.map { |u| ur[u] }].join(' '))
  end
end

`gnuplot overhead-vs-deps.plot`
