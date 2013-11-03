#!/usr/bin/env ruby

require 'bundler'
Bundler.require

require 'rgl/adjacency'
require 'rgl/dot'

class Operation
end

class User
  attr_accessor :ops

  def initialize(dag, num_ops)
    self.ops = num_ops.times.map { Operation.new }
    (self.ops.size - 1).times do |i|
      dag.add_edge(ops[i], ops[i+1])
    end
  end
end

class Generator
  def initialize(options)
    @num_users = options[:num_users]
    @total_ops = options[:total]
    @hash_size = options[:hash_size]
    @num_ops_per_users = @total_ops / @num_users
  end

  def generate
    @dag = RGL::DirectedAdjacencyGraph.new
    @users = @num_users.times.map { User.new(@dag, @num_ops_per_users) }
  end

  def write_file(output_file)
    File.open(output_file, "w") do |f|
      @num_ops_per_users.times do |op_index|
        @users.each
      end
    end
  end
end

class GenerateStream < Thor
  desc "generate output.json", "generate a syntetic workload"

  option :total,            :aliases => "-n",  :type => :numeric, :default => 10000, :desc => "Number of total operations"
  option :num_users,        :aliases => "-u",  :type => :numeric, :default => 1000,  :desc => "Number of users"

  option :max_num_friend,   :aliases => "-mf", :type => :numeric, :default => 100,   :desc => "Max friends"
  option :coeff_num_friend, :aliases => "-cf", :type => :numeric, :default => 1.5,   :desc => "Zipfian coeff friends"

  option :num_interactions_ratio,   :aliases => "-ri", :type => :numeric, :default => 0.3,   :desc => "Ratio of number of interactions"
  option :coeff_interactions_ratio, :aliases => "-ci", :type => :numeric, :default => 1.5,   :desc => "Zipfian coeff interactions"

  option :hash_size, :aliases => "-h", :type => :numeric, :default => 2*30, :desc => "Hash size, 0 to disable"

  def generate(output_file)
    g = Generator.new(options)
    g.generate
    g.write_file(output_file)
  end

  start(ARGV)
end
