require 'bundler'
require 'redis'
Bundler.require

$master = Redis.new(:url => 'redis://master/')
$worker_index = ENV['WORKER_INDEX'].to_i

# module Promiscuous::Redis
  # def self.new_connection(url=nil)
    # url ||= Promiscuous::Config.redis_urls
    # redis = ::Redis::Distributed.new(url, :timeout => 20, :tcp_keepalive => 60)
    # redis.info.each { }
    # redis
  # end
# end

class Promiscuous::Subscriber::Worker::MessageSynchronizer
  remove_const :CLEANUP_INTERVAL
  CLEANUP_INTERVAL = ENV['CLEANUP_INTERVAL'].to_i
  remove_const :QUEUE_MAX_AGE
  QUEUE_MAX_AGE    = ENV['QUEUE_MAX_AGE'].to_i
end

class Stats
  class << self; attr_accessor :benchs, :thread; end
  self.benchs = []
  self.thread = nil

  def self.main_loop
    loop do
      sleep 0.1

      $master.pipelined do
        self.benchs.each(&:publish)
      end
    end
  rescue Exception => e
    STDERR.puts "[stats] #{e}\n#{e.backtrace.join("\n")}"
    exit 1
  end

  def self.register(bench)
    self.benchs << bench
    self.thread ||= Thread.new { main_loop }
  end

  class Base
    def initialize(key)
      @mutex = Mutex.new
      @key = key
      Stats.register(self)
    end
  end

  class Counter < Base
    def initialize(key)
      @counter = 0
      super
    end

    def inc
      @mutex.synchronize { @counter += 1 }
    end

    def publish
      c = nil
      @mutex.synchronize { c, @counter = @counter, 0 }
      $master.incrby(@key, c) if c > 0
    end
  end

  class Average < Base
    def initialize(key)
      @total = 0
      @samples = 0
      super
    end

    def <<(value)
      @mutex.synchronize do
        @total += value
        @samples += 1
      end
    end

    def measure(&block)
      start = Time.now
      block.call
    ensure
      # 0.01ms precision
      self << ((Time.now - start) * 100000).round
    end

    def publish
      t = s = nil
      @mutex.synchronize do
        t, @total = @total, 0
        s, @samples = @samples, 0
      end

      $master.multi do
        $master.incrby("#{@key}:total", t)
        $master.incrby("#{@key}:samples", s)
      end
    end
  end
end

eval(JSON.parse(ENV['EVAL']).first) if ENV['EVAL']

def bootstrap(type)
  amqp_ip = nil

  case type
  when :pub
    $master.rpush("ip:pub", `hostname -i`.strip)
    amqp_ip = 'localhost'
  when :sub
    while amqp_ip.nil?
      amqp_ip = $master.lrange("ip:pub", $worker_index, $worker_index).first
      sleep 0.1
    end
  end

  Promiscuous.configure do |config|
    config.app = type.to_s
    config.amqp_url = "amqp://guest:guest@#{amqp_ip}:5672"
    config.subscriber_threads = ENV['NUM_THREADS'].to_i
    config.hash_size = ENV['HASH_SIZE'].to_i
    config.redis_urls = $master.lrange("ip:#{type}_redis", 0, -1)
                          .take(ENV['NUM_REDIS'].to_i)
                          .map { |r| "redis://#{r}/" }
    config.error_notifier = proc { exit 1 }
  end
  Promiscuous::Config.logger.level = ENV['LOGGER_LEVEL'].to_i

end

def add_instrumentation(type)
  case type
  when :pub
    $msg_count_bench = Stats::Counter.new('pub_msg')
    Promiscuous::Publisher::Operation::Ephemeral.class_eval do
      def execute
        super do
          $msg_count_bench.inc
          sleep ENV['PUB_LATENCY'].to_f if ENV['PUB_LATENCY']
        end
      end
    end
  when :sub
    $msg_count_bench = Stats::Counter.new('sub_msg')
    Promiscuous::Subscriber::Model.mapping.values.map(&:values).flatten.each do |klass|
      klass.after_save do
        $msg_count_bench.inc
        sleep ENV['SUB_LATENCY'].to_f if ENV['SUB_LATENCY']
      end
    end
  end
end

def finalize_bootstrap(type)
  add_instrumentation(type)
  case type
  when :pub
    loop do
      return if $master.get("start_pub")
      sleep 0.1
    end
  when :sub
    Promiscuous::Subscriber::Worker.new.start
    $master.rpush("ip:sub", `hostname -i`.strip)
  end
end
