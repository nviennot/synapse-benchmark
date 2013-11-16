#!/usr/bin/env ruby

require 'bundler'
Bundler.require

require 'rgl/adjacency'
require 'rgl/dot'

module DepID
  def self.included(klass)
    class << klass
      attr_accessor :counter
    end
    klass.counter = 0
  end

  def get_new_id
    self.class.counter += 1
  end
end

class Operation
  include DepID

  attr_accessor :serial
  attr_accessor :parent
  attr_accessor :id
  attr_accessor :user_id
  attr_accessor :user_serial
  attr_accessor :index

  def initialize(user, index)
    @id = get_new_id
    @user_id = user.id
    @index = index

    @serial = 1
    @user_serial = 1

    @parent = nil
  end

  def parent=(op)
    @user_serial = op.user_serial + 1
  end

  def dep
    "posts_id_#{@id}:#{@serial}"
  end

  def user_dep
    "users_id_#{@user_id}:#{@user_serial}"
  end

  def payload(rev_dag)
    payload = {}
    payload[:types] = ["Post"]
    payload[:operations] = [{:operation => :create}]
    payload[:app] ='test'
    payload[:current_user_id] = self.user_id
    payload[:dependencies] = { :write => [] }

    payload[:dependencies][:write] << user_dep
    payload[:dependencies][:write] << dep

    rev_dag.each_adjacent(self) do |op|
      payload[:dependencies][:read] ||= []
      payload[:dependencies][:read] << op.dep
    end

    payload
  end
end

class User
  include DepID
  attr_accessor :ops
  attr_accessor :id
  attr_accessor :friend_activity_distribution

  @@counter = 0
  def initialize(dag, rev_dag, num_ops)
    @id = get_new_id


    self.ops = num_ops.times.map { |i| Operation.new(self, i) }
    (self.ops.size - 1).times do |i|
      ops[i+1].parent = ops[i]

      dag.add_vertex(ops[i])
      dag.add_vertex(ops[i+1])

      rev_dag.add_vertex(ops[i])
      rev_dag.add_vertex(ops[i+1])
    end
  end
end

class Generator
  def initialize(options)
    @num_users = options[:num_users]

    @friend_distribution = Zipfian.new(options[:max_num_friends], options[:coeff_num_friends])
    @num_ops_per_users = options[:total] / @num_users

    @op_interaction_distribution = Zipfian.new((@num_ops_per_users * options[:num_interactions_ratio]).to_i + 1,
                                               options[:coeff_interactions_ratio])

    @coeff_friend_activity = options[:coeff_friend_activity]
  end

  def generate
    @dag = RGL::DirectedAdjacencyGraph.new
    @rev_dag = RGL::DirectedAdjacencyGraph.new
    @users = @num_users.times.map { User.new(@dag, @rev_dag, @num_ops_per_users) }

    @friend_graph = RGL::AdjacencyGraph.new
    @users.each do |user|
      @friend_graph.add_vertex(user)

      num_friends = @friend_distribution.sample

      user.friend_activity_distribution = Zipfian.new(num_friends, @coeff_friend_activity)

      num_new_friends = num_friends - @friend_graph.each_adjacent(user).size.to_i
      next unless num_new_friends > 0

      @users.sample(num_new_friends).each do |friend|
        next if user == friend
        @friend_graph.add_edge(user, friend)
      end
    end

    @users.each do |user|
      num_ops = @op_interaction_distribution.sample
      user.ops.sample(num_ops).each do |op|
        num_friend_activities = user.friend_activity_distribution.sample

        @friend_graph.each_adjacent(user).to_a.sample(num_friend_activities).each do |friend|
          friend_op = friend.ops[op.index+1..-1].sample

          @dag.add_edge(op, friend_op)
          @rev_dag.add_edge(friend_op, op)
        end
      end
    end
  end

  # def compute_deps
    # TGL::TopsortIterator.new(@dag).each do |op|
      # op.serial = @rev_dag.each_adjacent(v).size
    # end
  # end

  def write_file(output_file)
    File.open(output_file, "w") do |f|
      @num_ops_per_users.times do |op_index|
        @users.each do |user|
          f.puts MultiJson.dump(user.ops[op_index].payload(@rev_dag))
        end
      end
    end
  end
end

class GenerateStream < Thor
  desc "generate output.json", "generate a syntetic workload"

  option :total,            :aliases => "-n",  :type => :numeric, :default => 10000, :desc => "Number of total operations"
  option :num_users,        :aliases => "-u",  :type => :numeric, :default => 1000,  :desc => "Number of users"

  option :max_num_friends,   :aliases => "-f", :type => :numeric, :default => 100,   :desc => "Max friends"
  option :coeff_num_friends, :aliases => "-g", :type => :numeric, :default => 1.5,   :desc => "Zipfian coeff friends"

  option :num_interactions_ratio,   :aliases => "-i", :type => :numeric, :default => 0.3,   :desc => "Ratio of number of interactions"
  option :coeff_interactions_ratio, :aliases => "-k", :type => :numeric, :default => 1.5,   :desc => "Zipfian coeff interactions"

  option :coeff_friend_activity, :aliases => "-a", :type => :numeric, :default => 1.0,   :desc => "Zipfian coeff friend activity"

  option :hash_size, :aliases => "-h", :type => :numeric, :default => 2*30, :desc => "Hash size, 0 to disable"

  def generate(output_file)
    g = Generator.new(options)
    g.generate
    g.write_file(output_file)
  end

  start(ARGV)
end
