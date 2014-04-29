require 'promiscuous'

raise "DB_SERVER not specified" unless ENV['DB_SERVER']
ENV['DB_SERVER'] = ENV['DB_SERVER'].split(',').sample

module Model
  extend self
  CLASS_NAMES = %w(Post Comment)

  def definitions
    case ENV['DB']
    when 'nodb'      then Model::NoDB
    when 'mysql'     then Model::MySQL
    when 'postgres'  then Model::Postgres
    when 'mongodb'   then Model::MongoDB
    when 'cassandra' then Model::Cassandra
    when 'es'        then Model::ES
    when 'rethinkdb' then Model::RethinkDB
    when 'neo4j'     then Model::Neo4j
    when 'tokumx'    then Model::MongoDB
    end
  end
end

module Model::Base
  def connect
  end

  def load_models(type)
    connect

    define_models           if defined?(define_models)
    define_associations     if defined?(define_associations)
    define_attributes(type) if defined?(define_attributes)

    unless ENV['NUM_READ_DEPS'] == 'native'
      case type
      when :pub then define_publishers
      when :sub then define_subscribers
      end
    end
  end

  def prepare_db(type)
    if defined?(do_migration)
      connect
      do_migration(type)
    end
  end
end

module Model::Publishers
  def define_publishers
    ::Post.class_eval do
      include Promiscuous::Publisher
      publish :author_id, :content
    end
    ::Comment.class_eval do
      include Promiscuous::Publisher
      publish :author_id, :post_id, :content
    end
  end
end

module Model::Subscribers
  def define_subscribers
    ::Post.class_eval do
      include Promiscuous::Subscriber
      subscribe :author_id, :content, :from => 'pub'
    end
    ::Comment.class_eval do
      include Promiscuous::Subscriber
      subscribe :post_id, :author_id, :content, :from => 'pub'
    end
  end
end

module Model::Associations
  def define_associations
    ::Post.class_eval do
      has_many :comments
    end
    ::Comment.class_eval do
      belongs_to :post
    end
  end
end

module Model::NoDB
  extend Model::Base
  extend Model::Publishers
  extend Model::Subscribers
  extend self

  def define_models
    Model::CLASS_NAMES.each do |model|
      eval "class ::#{model}; end"
    end
  end
end

module Model::ActiveRecord
  def define_models
    Model::CLASS_NAMES.each do |model|
      eval "class ::#{model} < ActiveRecord::Base; end"
    end
  end

  def do_migration(type)
    eval <<-RUBY
      class ::Model::ActiveRecord::Migration < ActiveRecord::Migration
        def change
          create_table :posts #{type == :sub ? ', :id => false' : ''}, :force => true do |t|
            t.string :id, :limit => 40 if #{type == :sub}
            t.integer :author_id
            t.string :content
          end
          add_index(:posts, :author_id)

          create_table :comments #{type == :sub ? ', :id => false' : ''}, :force => true do |t|
            t.string :id, :limit => 40 if #{type == :sub}
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
  extend Model::Base
  extend Model::ActiveRecord
  extend Model::Publishers
  extend Model::Subscribers
  extend Model::Associations
  extend self

  def db_settings
    {
      :host     => ENV['DB_SERVER'],
      :adapter  => "mysql2",
      :database => "promiscuous",
      :username => "benchmark",
      :password => "pafpaf",
      :encoding => "utf8",
      :pool => 1,
    }
  end

  def connect
    require 'active_record'
    require 'mysql2'
    STDERR.puts ENV['DB_SERVER']
    ActiveRecord::Base.establish_connection(db_settings)
  end

  def do_migration(type)
    ActiveRecord::Base.establish_connection(db_settings.merge(:database => 'mysql'))
    ActiveRecord::Base.connection.drop_database(db_settings[:database]) rescue nil
    ActiveRecord::Base.connection.create_database(db_settings[:database])
    ActiveRecord::Base.establish_connection(db_settings)
    super
  end
end

module Model::Postgres
  extend Model::Base
  extend Model::ActiveRecord
  extend Model::Publishers
  extend Model::Subscribers
  extend Model::Associations
  extend self

  def db_settings
    {
      :host     => ENV['DB_SERVER'],
      :adapter  => "postgresql",
      :database => "promiscuous",
      :username => "postgres",
      :password => nil,
      :encoding => "utf8",
      :pool => 1,
    }
  end

  def connect
    require 'active_record'
    require 'mysql2'
    ActiveRecord::Base.establish_connection(db_settings)
  end

  def do_migration(type)
    ActiveRecord::Base.establish_connection(db_settings.merge('database' => 'postgres'))
    txids = ActiveRecord::Base.connection.execute("select gid from pg_prepared_xacts").column_values(0).to_a
    ActiveRecord::Base.establish_connection(db_settings)
    txids.each { |xid| ActiveRecord::Base.connection.execute("ROLLBACK PREPARED '#{xid}'") }
    ActiveRecord::Base.establish_connection(db_settings.merge('database' => 'postgres'))
    ActiveRecord::Base.connection.drop_database(db_settings[:database]) rescue nil
    ActiveRecord::Base.connection.create_database(db_settings[:database])
    ActiveRecord::Base.establish_connection(db_settings)
    super
  end
end

module Model::MongoDB
  extend Model::Base
  extend Model::Publishers
  extend Model::Subscribers
  extend Model::Associations
  extend self

  def connect
    require 'mongoid'
    Mongoid.configure do |config|
      config.load_configuration({
        sessions: {
          default: {
            database: 'benchmark',
            hosts: [ "#{ENV['DB_SERVER']}:27017" ],
            options: { safe: true }
          }
        }
      })
    end
  end

  def do_migration(type)
    Mongoid.purge!
    load_models(type)
    Post.create_indexes
    Comment.create_indexes
  end

  def define_models
    Model::CLASS_NAMES.each do |model|
      eval "class ::#{model}
        include Mongoid::Document
      end"
    end
  end

  def define_attributes(type)
    Post.class_eval do
      field :content
      field :author_id

      index :author_id => 1
    end
    Comment.class_eval do
      field :author_id
      field :content

      index :author_id => 1
      index :post_id => 1
    end
  end
end

module Model::Cassandra
  extend Model::Base
  extend Model::Publishers
  extend Model::Subscribers
  extend Model::Associations
  extend self

  def connect
    require 'cequel'
    connection = Cequel.connect(:host => ENV['DB_SERVER'], :keyspace => 'benchmark')
    Cequel::Record.connection = connection
  end

  def do_migration(type)
    Cequel::Record.connection.schema.drop! rescue nil
    Cequel::Record.connection.schema.create!
    load_models(type)

    Post.synchronize_schema
    Comment.synchronize_schema
  end

  def define_models
    Model::CLASS_NAMES.each do |model|
      eval "class ::#{model}
        include Cequel::Record
      end"
    end
  end

  def define_attributes(type)
    Post.class_eval do
      key :id, :timeuuid, auto: true if type == :pub
      key :id, :text                 if type == :sub
      column :content, :text
      column :author_id, :int
    end

    Comment.class_eval do
      key :id, :timeuuid, auto: true if type == :pub
      key :id, :text                 if type == :sub
      column :content, :text
      column :post_id, :text
      column :author_id, :text
    end
  end
end

module Model::ES
  extend Model::Base
  extend Model::Subscribers
  extend self

  def connect
    require './es'

    ENV['ELASTICSEARCH_URL'] = "http://#{ENV['DB_SERVER']}:9200/"
    ::ES.server
  end

  def do_migration(type)
    ::ES.delete_all_indexes
    load_models(type)
    ::ES.create_index(Post.name.underscore)
    ::ES.create_index(Comment.name.underscore)
    Post.update_mapping(:_all)
    Comment.update_mapping(:_all)
  end

  def define_models
    Model::CLASS_NAMES.each do |model|
      eval "class ::#{model} < ::ES::Model
              include Promiscuous::Subscriber::Model::Base

              def self.__promiscuous_fetch_existing(id)
                find(id)
              end

              def self.__promiscuous_duplicate_key_exception?(e)
                false
              end

              def save
                super(self.class.name.underscore)
              end

              def save!(*a)
                save(*a)
              end
            end"
    end
  end

  def define_attributes(type)
    Post.class_eval do
      property :_id,       :type => :string, :index    => :not_analyzed
      property :author_id, :type => :string, :index    => :not_analyzed
      property :content,   :type => :string, :analyzer => :simple
    end

    Comment.class_eval do
      property :_id,       :type => :string, :index    => :not_analyzed
      property :author_id, :type => :string, :index    => :not_analyzed
      property :post_id,   :type => :string, :index    => :not_analyzed
      property :content,   :type => :string, :analyzer => :simple
    end
  end
end

module Model::RethinkDB
  extend Model::Base
  extend Model::Associations
  extend Model::Subscribers
  extend self

  def connect
    require 'nobrainer'
    ENV['RETHINKDB_DB'] = 'benchmark'
    NoBrainer.configure do |c|
      c.rethinkdb_url = "rethinkdb://#{ENV['DB_SERVER']}/benchmark"
      c.logger = Logger.new(STDERR).tap { |l| l.level = ENV['LOGGER_LEVEL'].to_i }
    end
  end

  def do_migration(type)
    NoBrainer.drop!
    load_models(type)
    Post.first
    Comment.first
  end

  def define_models
    Model::CLASS_NAMES.each do |model|
      eval "class ::#{model}
              include NoBrainer::Document
              include Promiscuous::Subscriber::Model::Base

              def self.__promiscuous_fetch_existing(id)
                find!(id)
              end

              def self.__promiscuous_duplicate_key_exception?(e)
                false
              end
            end"
    end
  end

  def define_attributes(type)
    Post.class_eval do
      field :content
      field :author_id, :index => true
    end
    Comment.class_eval do
      field :author_id
      field :content
    end
  end
end

module Model::Neo4j
  extend Model::Base
  extend Model::Subscribers
  extend self

  def connect
    require 'neo4j'
    Neo4j::Session.open(:server_db, "http://#{ENV['DB_SERVER']}:7474")
  end

  def do_migration(type)
    Neo4j::Session.current.query <<-Q
      MATCH (n)
      OPTIONAL MATCH (n)-[r]-()
      DELETE n,r
    Q
  end

  def define_models
    Model::CLASS_NAMES.each do |model|
      eval "class ::#{model}
              include Neo4j::ActiveNode
              include Promiscuous::Subscriber::Model::Base

              def self.__promiscuous_fetch_existing(id)
                find!(id)
              end

              def self.__promiscuous_duplicate_key_exception?(e)
                false
              end
            end"
    end
  end

  def define_attributes(type)
    Post.class_eval do
      property :id
      property :content
      property :author_id
    end
    Comment.class_eval do
      property :id
      property :content
      property :post_id
      property :author_id
    end
  end
end
