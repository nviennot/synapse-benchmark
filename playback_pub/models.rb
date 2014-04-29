require 'promiscuous'

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
            t.timestamps
            t.integer :author_id
            t.string :content
          end
          add_index(:posts, :author_id)

          create_table :comments #{type == :sub ? ', :id => false' : ''}, :force => true do |t|
            t.string :id, :limit => 40 if #{type == :sub}
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
  extend Model::Base
  extend Model::ActiveRecord
  extend Model::Publishers
  extend Model::Subscribers
  extend Model::Associations
  extend self

  def db_settings
    {
      :adapter  => "mysql2",
      :database => "promiscuous",
      :username => "root",
      :password => "pafpaf",
      :encoding => "utf8",
      :pool => 20,
    }
  end

  def connect
    require 'active_record'
    require 'mysql2'
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
      :adapter  => "postgresql",
      :database => "promiscuous",
      :username => "postgres",
      :password => nil,
      :encoding => "utf8",
      :pool => 20,
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
      config.connect_to('benchmark', :safe => true)
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
        include Mongoid::Timestamps
      end"
    end
  end

  def define_attributes
    # User.class_eval do
      # field :name
    # end
    # Friendship.class_eval do
    # end
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
    connection = Cequel.connect(:host => 'localhost', :keyspace => 'benchmark')
    connection.logger = Logger.new(STDOUT).tap { |l| l.level = 0 }
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

  def define_attributes
    Post.class_eval do
      key :id, :timeuuid, auto: true
      column :content, :text
      column :author_id, :int
    end

    Comment.class_eval do
      key :id, :timeuuid, auto: true
      column :content, :text
      column :post_id, :text
      column :author_id, :text
    end
  end
end
