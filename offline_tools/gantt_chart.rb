#!/usr/bin/env ruby
require 'bundler'
require 'logger'
Bundler.require
require 'multi_json'
require 'optparse'

$force_single_thread = false
$output = "gantt_chart.pdf"
include_file = nil

class Slice < Hashie::Mash
  def duration
    self.end - self.start
  end

  def include?(p)
    (self.start...self.end).include?(p)
  end

  def thread_id
    $force_single_thread ? 1 : self.pid
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

  opts.on("-v", "--visual-cut start,end", Array, "Cut with lines") do |start_time, end_time|
    cuts << Slice.new(:type => :visual, :start => Float(start_time), :end => Float(end_time))
  end

  opts.on("-s", "--silent-cut start,end", Array, "Suppress some time") do |start_time, end_time|
    cuts << Slice.new(:type => :silent, :start => Float(start_time), :end => Float(end_time))
  end

  opts.on("-r", "--remove-slice app,start,end", Array, "Suppress some time") do |app, start_time, end_time|
    cuts << Slice.new(:type => :slient, :start => Float(start_time), :end => Float(end_time), :app => app)
  end

  opts.on("-t", "--single-thread", "Suppress some time") do
    $force_single_thread = true
  end

  opts.on("-o", "--output output", "Output PDF file") do |output|
    $output = output
  end

  opts.on("-i", "--include file", "Include a file") do |file|
    include_file = file
  end

include_file = nil
end.parse!

def parse_file(file)
  File.open(file).readlines.map do |line|
    next unless line =~ /^\[([^\]]+) ([0-9]+)-([0-9]+)\] ([^ ]+) ([0-9.]+)-([0-9.]+) (.*)$/
    options = {:app => $1, :pid => $2, :tid => $3, :type => $4.to_sym, :start => Float($5) * 1000, :end => Float($6) * 1000}
    options[:desc] = $7 unless $7.empty?
    slice = Slice.new(options)

    if slice.type == :app_controller && slice.desc =~ /(.+) -- (.+) -- (.+)/
      slice.desc = $1
      slice.current_user = $2
    elsif slice.type == :app_controller && slice.desc =~ /(.+) -- (.+)/
      slice.desc = $1
    elsif slice.type == :subscribe
      slice.current_user = MultiJson.load(slice.desc)['current_user_id'].to_s
    end
    slice
  end.compact
end

slices = parse_file(ARGV[0])
slices.sort_by!(&:start)

def apply_cuts(slices, cuts)
  slices.map do |slice|
    slice = slice.dup
    _start = slice.start
    _end = slice.end

    cuts.each do |cut|
      next if cut.app && cut.app != slice.app

      if [slice.start, slice.end].any? { |p| cut.include?(p) }
        _start = :remove
      end

      next if cut.app

      if slice.start >= cut.end
        _start -= cut.duration
        _end -= cut.duration
      elsif slice.end >= cut.end
        _end -= cut.duration
      end
    end

    next if _start == :remove

    slice.start = _start
    slice.end = _end
    slice
  end.compact
end

def auto_find_cuts(slices, cuts)
  total_duration = slices.map(&:end).max
  wanted_total_duration = 400
  wanted_total_duration = ENV['WANTED_DURATION'].to_i if ENV['WANTED_DURATION']
  min_cut_size = 0.10 * wanted_total_duration
  cut_margin = 0.02 * wanted_total_duration

  points = (slices.map(&:start) + slices.map(&:end)).flatten.sort
  intervals = points.each_cons(2).map do |left, right|
    Slice.new(:start => left + cut_margin, :end => right - cut_margin)
  end
  intervals = intervals.select { |i| i.duration > min_cut_size }.sort_by(&:duration)

  time_to_remove = total_duration - wanted_total_duration
  intervals.each do |cut|
    return unless time_to_remove > 0

    unless cuts.any? { |_cut| [cut.start, cut.end].any? { |c| _cut.include?(c) } }
      time_to_remove -= cut.duration
      cut.type = slices.any? { |s| s.start <= cut.start && s.end >= cut.end } ? :visual : :silent
      cuts << cut
    end
  end
end

slices = apply_cuts(slices, [Slice.new(:type => :silent, :start => 0.0, :end => slices.first.start)]) # resets the 0
orig_slices = slices.map(&:dup)
auto_find_cuts(slices, cuts) if cuts.empty?
slices = apply_cuts(slices, cuts)
cuts = cuts.sort_by(&:start)

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
    # next if slice.type == :db_prepare # not counting the prepare phase of the 2PC, it's our overhead

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
  puts "set terminal pdf dashed size 6,2"
  puts "set output '#{$output}'"
end

def mapping_of(slices, type)
  Hash[slices.group_by(&type)
             .map { |app, _slices| [app, _slices] }
             .sort_by { |as| as[1].first.app_index }
             .map { |app, _slices| [app, _slices.map(&:thread_id).uniq] }
  ]
end

$user_style = {}
def get_slice_style(slice)
  if ENV['SHOW_USERS']
    # For the key of the extra style
    if slice.type == :disconnect
      return "fc ls 1 fs pattern 5 bo -1"
    end

    styles = ["fc ls 4 fs pattern 7 bo -1",
              "fc ls 3 fs pattern 6 bo -1"]
    return "" unless slice.current_user
    $user_style[slice.current_user] ||= styles[$user_style.size]
  else
    styles = ["fc ls 4 fs pattern 2 bo -1",
              "fc ls 3 fs pattern 6 bo -1"]
    case slice.type
    when :publish   then styles[0]
    when :subscribe then styles[1]
    else ""
    end
  end
end

def next_rect_id
  $rect_id ||= 0
  $rect_id += 1
end

def print_slices(slices)
  if ENV['SHOW_USERS']
    slices = slices.select { |s| s.type == :app_controller || s.type == :subscribe }
  end

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

  puts "set ytics axis nomirror font 'Times-Roman,14'"
  puts "set yrange [-0.5:#{apps.count + 0.3}]"
  puts "set mytics 0.1"

  ytics = apps.each_with_index.map do |at, i|
    app, threads = at
    if threads.size == 1 || ENV['ANNOTATE_THREADS'] == '0'
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

def print_xaxis(slices, cuts)
  tic_every = 15
  tic_every = ENV['XTICS'].to_i if ENV['XTICS']
  cut_display_size = 5

  has_visual_cut = cuts.any? { |c| c.type == :visual }

  apps = mapping_of(slices, :app_name)
  xmin = slices.map(&:start).min
  xmax = slices.map(&:end).max

  # xmax = (xmax.to_i/tic_every+1)*tic_every - 10
  xmax *= 1.01

  puts "set xlabel 'Time [ms]'"
  puts "set xtics font 'Times-Roman,14'"
  puts "set xrange [#{xmin}:#{xmax}]"
  puts "set grid xtics"

  xtics = []

  def print_tics(has_visual_cut, tic_every, xtics, real_left, real_right, effective_offset)
    effective_offset = effective_offset.to_i
    (real_left.to_i..real_right.to_i).each do |x|
      if (effective_offset+x) % tic_every == 0
        # unless [(x-real_left).abs, (x-real_right).abs].min < 10
          xtics << "'' #{x}"
          y = has_visual_cut ? -1.0 : -0.7
          puts "set label '#{effective_offset+x}' at #{x},#{y} center"
        # end
      end
    end
  end

  if cuts.empty?
    print_tics(has_visual_cut, tic_every, xtics, 0, xmax, 0)
  else
    last_cut = nil
    real_offset = 0
    cut_offset = 0
    last_real_right_cut = 0

    cuts.reject(&:app).each do |cut|
      if cut.type == :silent
        cut_offset += cut.duration
        next
      end

      real_left_cut = cut.start - cut_offset
      real_right_cut = real_left_cut + cut_display_size

      if last_cut
        print_tics(has_visual_cut, tic_every, xtics, last_real_right_cut, real_left_cut, real_offset)
      else
        print_tics(has_visual_cut, tic_every, xtics, 0, cut.start, 0)
      end

      coords1 = "from #{real_left_cut},#{-0.7} to #{real_left_cut},#{apps.count+0.5}"
      coords2 = "from #{real_right_cut},#{-0.7} to #{real_right_cut},#{apps.count+0.5}"
      coordsr = "from #{real_left_cut+1},#{-2} to #{real_right_cut-1},#{apps.count+0.5}"
      puts "set object #{next_rect_id} rect #{coordsr} fs solid 1.0 noborder"

      puts "set arrow #{coords1} nohead ls 5 lc 0 lw 4"
      puts "set arrow #{coords2} nohead ls 5 lc 0 lw 4"

      last_cut = cut

      cut_offset += cut.duration
      real_offset += cut.duration
      last_real_right_cut = real_right_cut
    end
    print_tics(has_visual_cut, tic_every, xtics, last_real_right_cut, xmax, real_offset)
  end

  puts "set xtics (#{xtics.flatten.join(",")})"
end

def print_key(slices)
  apps = mapping_of(slices, :app_name)
  total_duration = slices.map(&:end).max

  # xlow_key = 0.51 * total_duration
  # xhigh_key = 1.05 * total_duration

  xlow_key = 0.02 * total_duration

  if ENV['SHOW_USERS']
    # xhigh_key = 0.4 * total_duration
    xhigh_key = 0.93 * total_duration
  else
    xhigh_key = 1.05 * total_duration
  end

  ylow_key = apps.count - 0.3
  yhigh_key = apps.count

  coords = "from #{xlow_key},#{ylow_key-0.2} to #{xhigh_key-10},#{yhigh_key+0.2}"
  puts "set object #{next_rect_id} rect #{coords} front fs solid 0 noborder"

  items = {'Application/DB'    => {:type => :app},
           'Synapse publish'   => {:type => :publish},
           'Synapse subscribe' => {:type => :subscribe}}

  if ENV['SHOW_USERS']
    items = {'User 1 context' => {:current_user => $user_style.keys[0]},
             'User 2 context' => {:current_user => $user_style.keys[1]},
             'Disconnected'   => {:type         => :disconnect }}
  end

  key_offset = xlow_key
  items.each do |name, style|
    xlow = key_offset
    xhigh = xlow + 0.05 * total_duration
    ylow = ylow_key
    yhigh = yhigh_key

    xlabel = xhigh + 0.005 * total_duration
    ylabel = ylow + (yhigh - ylow)*0.5

    coords = "from #{xlow},#{ylow} to #{xhigh},#{yhigh}"
    puts "set object #{next_rect_id} rect #{coords} front #{get_slice_style(Slice.new(style))}"
    puts "set label '#{name}' at #{xlabel},#{ylabel} front"

    key_offset += (xhigh_key - xlow_key)/items.size.to_f*0.9
  end

  puts "set nokey"
end

def print_finalize(include_file)
  puts File.open(include_file).read if include_file
  puts "plot -5"
end

print_header(slices)
print_slices(slices)
print_yaxis(slices)
print_xaxis(slices, cuts)
print_key(slices)
print_finalize(include_file)

(cuts + slices + orig_slices).each { |s| s.start = s.start.round(0); s.end = s.end.round(0) }
AwesomePrint.force_colors = true
STDERR.puts tree.ai
STDERR.puts "-" * 80
STDERR.puts cuts.ai
