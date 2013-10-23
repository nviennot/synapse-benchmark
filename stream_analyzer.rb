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
    op.dependencies[:write].each do |dep|
      d, v = dep.split(':').each(&:to_i)
      self.deps[d] ||= {}
      self.deps[d][v] = op
    end

    self.ops << op
  end

  def compile
    dag = RGL::DirectedAdjacencyGraph.new

    # Adding all the read dependencies
    self.ops.each do |op|
      op.dependencies[:read].to_a.each do |dep|
        d, v = dep.split(':').each(&:to_i)
        parent = (self.deps[d] || {})[v]

        if parent.nil?
          STDERR.puts "WARNING: cannot find dependency #{dep}"
          parent = dep
        end

        dag.add_edge(parent, op)
      end
    end

    # Each write dependencies is serialized
    self.deps.values.each do |versions_op|
      ops = versions_op.sort_by { |v,op| v }.map { |v,op| op }
      (ops.size - 1).times do |i|
        dag.add_edge(ops[i], ops[i+1])
      end
    end

    # TODO Check that we have no holes in the write dependency chain
    dag
  end

  def show
    dag = self.compile
    dag.write_to_graphic_file('png')
    # system("gwenview graph.png")
    system("kgraphviewer graph.dot")
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
    "#{self.operation[0]} #{self.klass} #{self.dependencies[:write].first}"
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
