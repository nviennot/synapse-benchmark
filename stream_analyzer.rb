#!/usr/bin/env ruby

require 'bundler'
Bundler.require

require 'rgl/adjacency'
require 'rgl/dot'

class DepGraph
  attr_accessor :deps, :ops

  def initialize
    self.deps = {}
    self.ops = []
  end

  def <<(op)
    op.dependencies[:write].to_a.each do |dep|
      d, v = dep.split(':').map(&:to_i)
      self.deps[d] ||= {}
      self.deps[d][v] ||= {}

      return if self.deps[d][v][:op]

      self.deps[d][v][:op] = op
    end

    op.dependencies[:read].to_a.each do |dep|
      d, v = dep.split(':').map(&:to_i)
      self.deps[d] ||= {}
      self.deps[d][v] ||= {}
      self.deps[d][v][:read_children] ||= []
      self.deps[d][v][:read_children] << op
    end

    self.ops << op
  end

  def compile
    dag = RGL::DirectedAdjacencyGraph.new

    self.deps.each do |d,all_versions|
      all_versions.each do |k,v|
        # Fill in empty operations
        v[:op] ||= "#{d}:#{k}"
      end
    end

    self.deps.each do |d, versions_op|
      ops = versions_op.sort_by { |v, _| v }.map { |v, op| op }
      #binding.pry if d == 925475

      (ops.size - 1).times do |i|
        read_children = ops[i][:read_children].to_a
        if read_children.empty?
          dag.add_edge(ops[i][:op], ops[i+1][:op])
        else
          read_children.each do |read_child|
            dag.add_edge(ops[i][:op], read_child)
            dag.add_edge(read_child, ops[i+1][:op])
          end
        end
      end
    end

    # TODO Check that we have no holes in the write dependency chain
    dag
  end

  def show
    dag = self.compile
    dag.write_to_graphic_file('png')
    system("chromium graph.png")
    #system("kgraphviewer graph.dot")
  end
end

class Operation
  attr_accessor :klass, :id, :operation, :dependencies

  def initialize(payload)
    self.klass        = payload[:type]
    self.id           = payload[:id]
    self.operation    = payload[:operation]
    self.dependencies = payload[:dependencies]
  end

  def to_s
    "#{self.operation[0]} #{self.klass} #{self.dependencies[:write].join(",")}"
  end
end

class StreamAnalyzer < Thor
  desc "show input.json", "show the corresponding graph of the input file"
  option :skip,  :aliases => "-s", :type => :numeric, :default => 0,  :desc => "skip N lines from the input"
  option :count, :aliases => "-c", :type => :numeric, :default => -1, :desc => "only read N lines from the input"
  def show(input_file)
    skip = options[:skip]
    count = options[:count]

    graph = DepGraph.new

    File.open(input_file).each do |line|
      (skip -= 1; next) if skip > 0
      (break if count == 0); count -= 1

      graph << Operation.new(MultiJson.load(line, :symbolize_keys => true))
    end

    graph.show
  end

  start(ARGV)
end
