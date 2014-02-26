#!/usr/bin/env ruby

r = {}

File.open('results').each do |line|
  line = line.gsub(/#.*$/, '').gsub(/[\t ]+/, ' ').strip
  next if line.empty?

  items = line.chomp.gsub(/[\t ]+/, ' ').split(' ')
  if items.size == 3
    users = items[0]
    workers = items[1]
    rate = items[2]

    r[workers] ||= {}
    r[workers][users] = rate
  end
end

users = r.values.map(&:keys).flatten.uniq

File.open('throughput-vs-workers.dat', 'w') do |f|
  r.each do |workers, ur|
    f.puts([workers, *users.map { |u| ur[u] }].join(' '))
  end
end

`gnuplot throughput-vs-workers.plot`
