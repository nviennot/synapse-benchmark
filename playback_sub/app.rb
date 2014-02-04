$current_worker = ENV['WORKER_INDEX'].to_i
$master_worker = $current_worker == 0

class Promiscuous::Subscriber::Worker::MessageSynchronizer
  remove_const :CLEANUP_INTERVAL
  CLEANUP_INTERVAL = 2
  remove_const :QUEUE_MAX_AGE
  QUEUE_MAX_AGE    = 5
end

Promiscuous.configure do |config|
  config.app = 'playback'
  config.backend = :file
  config.subscriber_amqp_url = "#{ENV['PLAYBACK_FILE']}:#{ENV['WORKER_INDEX']}:#{ENV['NUM_WORKERS']}"
  config.prefetch = 100
  config.subscriber_threads = 1
  config.stats_interval = $master_worker ? 3 : 10000
  config.on_stats = proc { |rate, latency| on_stats(rate) }
  # config.redis_urls = 2.times.map { |i| "redis://localhost:#{6379+i}" }
end

Promiscuous::Config.logger.level = 1

$message_count = 0

def on_stats(rate)
  num_samples = 20
  num_average = num_samples / 2

  if !@warming_up
    @warming_up = true
    return
  end

  @rates ||= []
  @rates << rate
  STDERR.puts "Sampling: #{@rates.size}/#{num_samples}"
  return unless @rates.size == num_samples

  avg_rate = @rates.sort_by { |x| -x }.take(num_average).reduce(:+) / num_average
  STDERR.puts "Sampling avg rate: #{avg_rate}"
  Promiscuous::Redis.master.set('rate', avg_rate)
  Promiscuous::Redis.master.set('kill_workers', 1)
  Process.kill("SIGTERM", Process.pid)
end

Thread.new do
  loop do
    sleep 1
    if Promiscuous::Redis.master.get('kill_workers')
      Process.kill("SIGTERM", Process.pid)
    end
  end
end

# Thread.new do
  # loop do
    # old_count = $message_count
    # next if old_count == 0
    # sleep 10

    # if $message_count == old_count
      # Promiscuous::Redis.master.set('kill_workers', 1)
      # Promiscuous.info "Deadlocked :("
      # exit 1
    # end
  # end
# end

def wait_for_workers
  n = ENV['NUM_WORKERS'].to_i
  return if n.zero?
  Promiscuous::Redis.master.incr("num_workers")

  loop do
    return if Promiscuous::Redis.master.get("num_workers").to_i == n
    sleep 0.2
  end
end

class Post
  include Promiscuous::Subscriber::Model::Observer
  subscribe

  after_create do
    $message_count += 1
    sleep ENV['SUB_LATENCY'].to_f
  end
end

wait_for_workers
