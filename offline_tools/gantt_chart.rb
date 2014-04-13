#!/usr/bin/env ruby
require 'bundler'
require 'logger'
Bundler.require
require 'multi_json'
require 'optparse'

class Slice < Hashie::Mash
  def duration
    self.end - self.start
  end

  def include?(p)
    (self.start...self.end).include?(p)
  end

  def thread_id
    self.pid
  end

  def app_name
    case app
    when 'diaspora'       then 'Diaspora'
    when 'diaspora_topic' then 'Semantic analyser'
    when 'diaspora_email' then 'Mailer'
    when 'spree_app'      then 'Spree'
    else app
    end
  end

  def app_index
    case app
    when 'diaspora'       then 3
    when 'diaspora_topic' then 1
    when 'diaspora_email' then 2
    when 'spree_app'      then 0
    end
  end
end

cuts = []
OptionParser.new do |opts|
  opts.banner = "Usage: gantt_chart.rb FILE [options] | gnuplot"

  opts.on("-c", "--visual-cut start,end", Array, "Cut with lines") do |start_time, end_time|
    cuts << Slice.new(:type => :visual, :start => Float(start_time), :end => Float(end_time))
  end

  opts.on("-s", "--silent-cut start,end", Array, "Suppress some time") do |start_time, end_time|
    cuts << Slice.new(:type => :silent, :start => Float(start_time), :end => Float(end_time))
  end
end.parse!

def parse_file(file)
  File.open(file).readlines.map do |line|
    next unless line =~ /^\[([^\]]+) ([0-9]+)-([0-9]+)\] (.+) (.+)-([^ ]+) (.*)$/
    options = {:app => $1, :pid => $2, :tid => $3, :type => $4.to_sym, :start => Float($5) * 1000, :end => Float($6) * 1000}
    options[:desc] = $7 unless $7.empty?
    Slice.new(options)
  end.compact
end

slices = parse_file(ARGV[0])
slices.sort_by!(&:start)

def apply_cuts(slices, cuts)
  slices.each do |slice|
    _start = slice.start
    _end = slice.end

    cuts.each do |cut|
      if [slice.start, slice.end].any? { |p| cut.include?(p) }
        STDERR.puts "Bad cut #{cut} on slice #{slice}"
        exit 1
      end

      if slice.start >= cut.end
        _start -= cut.duration
        _end -= cut.duration
      elsif slice.end >= cut.end
        _end -= cut.duration
      end
    end

    slice.start = _start
    slice.end = _end
  end
end

def auto_find_cuts(slices, cuts)
  total_duration = slices.map(&:end).max
  wanted_total_duration = 3000
  min_cut_size = 0.10 * wanted_total_duration
  cut_margin = 0.01 * wanted_total_duration

  points = (slices.map(&:start) + slices.map(&:end)).flatten.sort
  intervals = points.each_cons(2).map { |left, right| Slice.new(:start => left + cut_margin, :end => right - cut_margin) }
  intervals = intervals.select { |i| i.duration > min_cut_size }.sort_by(&:duration)

  time_to_remove = total_duration - wanted_total_duration
  intervals.each do |cut|
    return unless time_to_remove > 0
    unless (cuts.map(&:start) + cuts.map(&:end)).flatten.any? { |p| cut.include?(p) }
      time_to_remove -= cut.duration
      cut.type = slices.any? { |s| s.start <= cut.start && s.end >= cut.end } ? :visual : :silent
      cuts << cut
    end
  end
end

apply_cuts(slices, [Slice.new(:type => :silent, :start => 0.0, :end => slices.first.start)]) # resets the 0
orig_slices = slices.map(&:dup)
auto_find_cuts(slices, cuts)
apply_cuts(slices, cuts)

def build_tree(slices, parent=nil)
  slices = slices.dup
  layer = []
  until slices.empty?
    current_slice = slices.shift
    contained_slices, slices = slices.partition { |s| s.start < current_slice.end }
    current_slice.children = build_tree(contained_slices, current_slice)
    layer << current_slice
  end
  layer
end

tree = slices.group_by { |s| "#{s.app}-#{s.thread_id}" }.map { |_, s| build_tree(s) }.flatten(1)

def cleanup_tree(tree)
  tree = tree.map do |slice|
    next if slice.type == :publish && slice.desc.nil?
    next if slice.type == :db_prepare # not counting the prepare phase of the 2PC, it's our overhead

    children = slice.children
    if slice.type == :app_controller || slice.type == :subscribe
      children = children.reject { |c| c.type == :db_non_instrumented }
    end

    slice.merge(:children => cleanup_tree(children))
  end.compact

  (tree.size - 1).times do |i|
    if tree[i].type == :db_non_instrumented && tree[i+1].type == :app_controller
      tree[i+1].start = tree[i].start
      tree[i] = nil
    end
  end
  tree.compact
end
tree = cleanup_tree(tree)

def destack_tree(tree)
  tree.map { |s| [s] + destack_tree(s.children) }.flatten
end
slices = destack_tree(tree).sort_by(&:start)

def print_header(slices)
  puts <<-PLOT
set terminal pdf dashed size 14,2
set output "gantt_chart.pdf"
  PLOT
end

def mapping_of(slices, type)
  Hash[slices.group_by(&type)
             .map { |app, _slices| [app, _slices] }
             .sort_by { |as| as[1].first.app_index }
             .map { |app, _slices| [app, _slices.map(&:thread_id).uniq] }
  ]
end

def get_slice_style(slice)
  case slice.type
  when :publish   then "fc ls 4 fs pattern 2 bo -1"
  when :subscribe then "fc ls 3 fs pattern 6 bo -1"
  else ""
  end
end

def next_rect_id
  $rect_id ||= 0
  $rect_id += 1
end

def print_slices(slices)
  apps = mapping_of(slices, :app)
  num_threads = apps.values.map(&:size).max

  slices.each_with_index do |slice, i|
    num_threads = apps[slice.app].count
    app_index = apps.keys.index(slice.app)
    thread_index = num_threads - apps[slice.app].index(slice.thread_id) - 1

    ylow_app = app_index - 0.4
    yhigh_app = app_index + 0.4

    bar_height = (yhigh_app - ylow_app) / num_threads
    ylow = ylow_app + bar_height * thread_index
    yhigh = ylow + bar_height

    coords = "from #{slice.start},#{ylow} to #{slice.end},#{yhigh}"
    puts "set object #{next_rect_id} rect #{coords} #{get_slice_style(slice)}"
  end
end

def print_yaxis(slices)
  apps = mapping_of(slices, :app_name)

  puts "set ytics font 'Times-Roman,14'"
  puts "set yrange [-0.5:#{apps.count + 0.3}]"

  ytics = apps.each_with_index.map do |at, i|
    app, threads = at
    if threads.size == 1
      "'#{app}' #{i}"
    else
      threads.each_with_index.map do |t,j|
        tname = {1 => 'web frontend', 0 => 'background worker'}[j]
        "'(#{tname}) #{app}' #{i + j/threads.size.to_f - 0.3}"
      end
    end
  end
  puts "set ytics (#{ytics.flatten.join(",")})"
end

def print_xaxis(slices)
  xmin = slices.map(&:start).min
  xmax = slices.map(&:end).max

  puts "set xlabel 'Time [ms]'"
  puts "set xtics font 'Times-Roman,14'"
  puts "set xrange [#{xmin}:#{(xmax.to_i/50+1)*50}]"
  puts "set grid xtics"
end

def print_key(slices)
  apps = mapping_of(slices, :app_name)
  total_duration = slices.map(&:end).max

  xlow_key = 0.01 * total_duration
  xhigh_key = 0.55 * total_duration

  ylow_key = apps.count - 0.3
  yhigh_key = apps.count

  coords = "from #{xlow_key},#{ylow_key-0.2} to #{xhigh_key},#{yhigh_key+0.2}"
  puts "set object #{next_rect_id} rect #{coords} fs solid 0 noborder"

  items = {'Application/DB'    => :app,
           'Synapse publish'   => :publish,
           'Synapse subscribe' => :subscribe}
  key_offset = xlow_key
  items.each do |name, style|
    xlow = key_offset
    xhigh = xlow + 0.05 * total_duration
    ylow = ylow_key
    yhigh = yhigh_key

    xlabel = xhigh + 0.005 * total_duration
    ylabel = ylow + (yhigh - ylow)*0.5

    coords = "from #{xlow},#{ylow} to #{xhigh},#{yhigh}"
    puts "set object #{next_rect_id} rect #{coords} #{get_slice_style(Slice.new(:type => style))}"
    puts "set label '#{name}' at #{xlabel},#{ylabel}"

    key_offset += (xhigh_key - xlow_key)/items.size.to_f
  end

  puts "set nokey"
  puts "plot -5"
end

print_header(slices)
print_slices(slices)
print_yaxis(slices)
print_xaxis(slices)
print_key(slices)

(cuts + slices + orig_slices).each { |s| s.start = s.start.round(0); s.end = s.end.round(0) }
AwesomePrint.force_colors = true
STDERR.puts tree.ai
STDERR.puts "-" * 80
STDERR.puts cuts.sort_by(&:start).ai
