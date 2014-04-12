#!/usr/bin/env ruby
require 'bundler'
require 'logger'
Bundler.require
require 'multi_json'
require 'optparse'

class Span < Hashie::Mash
  def duration
    self.end - self.start
  end

  def include?(p)
    (self.start...self.end).include?(p)
  end
end

cuts = []
OptionParser.new do |opts|
  opts.banner = "Usage: gantt_chart.rb FILE [options] | gnuplot"

  opts.on("-c", "--visual-cut start,end", Array, "Cut with lines") do |start_time, end_time|
    cuts << Span.new(:type => :visual, :start => Float(start_time), :end => Float(end_time))
  end

  opts.on("-s", "--silent-cut start,end", Array, "Suppress some time") do |start_time, end_time|
    cuts << Span.new(:type => :silent, :start => Float(start_time), :end => Float(end_time))
  end
end.parse!

def parse_file(file)
  File.open(file).readlines.map do |line|
    next unless line =~ /^\[([^\]]+)\] (.+) (.+)-(.+) ({.*)$/
    Span.new(:app => $1, :type => $2.to_sym, :start => Float($3) * 1000, :end => Float($4) * 1000)
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
  cut_margin = 0.01 * total_duration
  min_cut_size = 0.2 * total_duration
  min_slice_size = 0.01

  wanted_total_duration = slices.map(&:duration).min / min_slice_size

  points = (slices.map(&:start) + slices.map(&:end)).flatten.sort
  intervals = points.each_cons(2).map { |left, right| Span.new(:start => left + cut_margin, :end => right - cut_margin) }
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

apply_cuts(slices, [Span.new(:type => :silent, :start => 0.0, :end => slices.first.start)]) # resets the 0
orig_slices = slices.map(&:dup)
auto_find_cuts(slices, cuts)
apply_cuts(slices, cuts)

def print_header(slices)
  xmin = slices.map(&:start).min
  xmax = slices.map(&:end).max
  apps = slices.map(&:app).uniq

  puts <<-PLOT
set terminal pdf dashed size 6,2
set output "gantt_chart.pdf"

# set ylabel "Application" font "Times-Roman,14"
#set ylabel offset +1.2,0
set yrange [0:#{apps.count}]

set xlabel "Time [ms]" font "Times-Roman,14"
#set xlabel offset 0,+1
set xrange [#{xmin}:#{(xmax.to_i/50+1)*50}]
set xtics font "Times-Roman,14"
set ytics font "Times-Roman,14"

# set grid ytics
set grid xtics

set style arrow 1 heads size screen 0.008,90 lw 10 lc 1
set style arrow 2 heads size screen 0.008,90 lw 10 lc 2

# set key reverse top left font "Times-Roman,14"
set nokey
  PLOT
end

def print_slices(slices)
  apps = slices.map(&:app).uniq
  slices.each_with_index do |slice, i|
    app_index = apps.count - apps.index(slice.app) - 1
    style = slice.type == :publish ? "fc ls 3 fs pattern 6 bo -1" : ""
    puts "set object #{i+1} rect from #{slice.start},#{app_index+0.2} to #{slice.end},#{app_index+0.8} #{style}"
  end
end

def print_axis(slices)
  apps = slices.map(&:app).uniq.reverse
  ytics = apps.each_with_index.map { |a,i| "\"#{a}\" #{i+0.5}" }
  puts "set ytics (#{ytics.join(",")})"
end

print_header(slices)
print_slices(slices)
print_axis(slices)
puts "plot 0"

(cuts + slices + orig_slices).each { |s| s.start = s.start.round(0); s.end = s.end.round(0) }
AwesomePrint.force_colors = true
STDERR.puts orig_slices.ai
STDERR.puts "-" * 80
STDERR.puts cuts.ai
