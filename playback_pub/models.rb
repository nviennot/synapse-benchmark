module Model
  extend self
  CLASS_NAMES = %w(User Friendship Post Comment)

  def definitions
    case ENV['DB']
    when 'nodb'      then Model::NoDB
    when 'mysql'     then Model::MySQL
    when 'postgres'  then Model::Postgres
    when 'mongodb'   then Model::MongoDB
    when 'cassandra' then Model::Cassandra
    end
  end
end

module Model::Base
  def connect
  end

  def load_models(type)
    connect

    define_models       if defined?(define_models)
    define_associations if defined?(define_associations)
    define_attributes   if defined?(define_attributes)

    case type
    when :pub then define_publishers
    when :sub then define_subscribers
    end
  end

  def prepare_db
    if defined?(do_migration)
      connect
      do_migration
    end
  end
end

module Model::Publishers
  def define_publishers
    User.class_eval do
      include Promiscuous::Publisher
      publish :name
      publish :created_at, :updated_at
    end
    Friendship.class_eval do
      include Promiscuous::Publisher
      publish :created_at, :updated_at
      publish :user1_id, :user2_id
    end
    Post.class_eval do
      include Promiscuous::Publisher
      publish :created_at, :updated_at
      publish :author_id
      publish :content
    end
    Comment.class_eval do
      include Promiscuous::Publisher
      publish :created_at, :updated_at
      publish :author_id
      publish :post_id
      publish :content
    end
  end
end

module Model::Associations
  def define_associations
    User.class_eval do
      has_many :friendships, :foreign_key => :user1_id
      has_many :comments, :foreign_key => :author_id
      has_many :posts, :foreign_key => :author_id
    end
    Friendship.class_eval do
      belongs_to :user1, :class_name => :User
      belongs_to :user2, :class_name => :User
    end
    Post.class_eval do
      belongs_to :author, :class_name => :User
      has_many :comments
    end
    Comment.class_eval do
      belongs_to :post
      belongs_to :author, :class_name => :User
    end
  end
end

module Model::NoDB
  include Model::Base
  include Model::Publishers

  def define_models
    MODELS.each do |model|
      eval "class #{model}; end"
    end
  end
end

module Model::ActiveRecord
  include Model::Base
  include Model::Publishers
  include Model::Associations

  def define_models
    Model::CLASS_NAMES.each do |model|
      eval "class #{model} < ActiveRecord::Base; end"
    end
  end

  def do_migration
    eval <<-RUBY
      class Model::ActiveRecord::Migration < ActiveRecord::Migration
        TABLES = [:users, :friendships, :posts, :comments]

        def change
          create_table :users, :force => true do |t|
            t.timestamps
            t.string :name
          end

          create_table :friendships, :force => true do |t|
            t.timestamps
            t.integer :user1_id
            t.integer :user2_id
          end
          add_index(:friendships, :user1_id)

          create_table :posts, :force => true do |t|
            t.timestamps
            t.integer :author_id
            t.string :content
          end
          add_index(:posts, :author_id)

          create_table :comments, :force => true do |t|
            t.timestamps
            t.integer :author_id
            t.integer :post_id
            t.string :content
          end
          add_index(:comments, :author_id)
          add_index(:comments, :post_id)
        end

        migrate :up
      end
    RUBY
  end
end

module Model::MySQL
  extend self
  include Model::ActiveRecord

  def connect
    require 'activerecord'
    require 'mysql2'
    #TODO
  end
end

module Model::Postgres
  extend self
  include Model::ActiveRecord

  def connect
    require 'activerecord'
    require 'pg'
    #TODO
  end
end

module Model::MongoDB
  extend self
  include Model::Base
  include Model::Publishers
  include Model::Associations

  def connect
    require 'mongoid'
    #TODO
  end

  def do_migration
    # TODO
  end

  def define_models
    MODELS.each do |model|
      eval "class #{model}
        include Mongoid::Document
        include Mongoid::Timestamps
      end"
    end
  end

  def define_attributes
    User.class_eval do
      field :name
    end
    Friendship.class_eval do
    end
    Post.class_eval do
      field :content
    end
    Comment.class_eval do
      field :content
    end
  end
end

module Model::Cassandra
  extend self
  include Model::Base
  include Model::Publishers
  include Model::Associations

  def connect
    require 'cequel'
    #TODO
  end

  def do_migration
    # TODO
  end

  def define_models
    MODELS.each do |model|
      eval "class #{model}
        include Cequel::Record

        attr_accessor :created_at, :updated_at
        def created_at
          super || Time.now
        end
        def updated_at
          super || Time.now
        end
      end"
    end
  end

  # def define_associations
    # # TODO
    # # not sure what to do
  # end

  def define_attributes
    User.class_eval do
      key :id, :timeuuid, auto: true
      column :name, :text
    end
    Friendship.class_eval do
      key :id, :timeuuid, auto: true
    end
    Post.class_eval do
      key :id, :timeuuid, auto: true
      column :content, :text
    end
    Comment.class_eval do
      key :id, :timeuuid, auto: true
      column :content, :text
    end
  end
end
