

require 'json'
require 'securerandom'
require 'open3'
require 'thread'
require 'rack'
require 'logger'

$log = Logger.new(STDERR)
$log.level = Logger::DEBUG

$lock = Mutex.new
$state = :sleep
$lastreq = Time.now - 3600
$poke = ConditionVariable.new

$upstream = nil
$token = nil

$poker = Thread.new do
  loop do
    $lock.synchronize do
      $log.debug 'waiting for a request'
      while Time.now - $lastreq > 300
        $poke.wait($lock)
      end

      $state = :starting
      $upstream = nil
      $token = nil
    end
    sleep 10

    $log.debug('getting interface info from gpu node')
    ENV['SSH_AUTH_SOCK'] = '/run/zone-auth-agent.sock'
    output, status = Open3.capture2e('ssh', 'gpu',
      "/usr/bin/ruby -e 'require \"socket\"; require \"json\";
      puts JSON.dump(Socket.getifaddrs.reject { |i| !i.addr.ip? }.
      map { |i| {name: i.name, addr: i.addr.ip_address} })'")
    next if status.exitstatus != 0
    remifaddrs = JSON.parse(output, symbolize_names: true)
    remif = remifaddrs.find { |a| a[:addr] =~ /^100[.]64[.]/ }
    next if remif.nil?
    $log.debug("ok: #{remif.inspect}")

    token = SecureRandom.hex(16)
    port = rand(1024..65535)

    $log.info('starting new jupyter on gpu node')

    output, status = Open3.capture2e('ssh', 'gpu', 'tmux kill-session -t jupyter')
    next unless [0,1].include?(status.exitstatus)

    cmd = "export PATH=/conda/bin:$PATH; tmux new-session -d -s jupyter 'jupyter-lab --no-browser --ServerApp.ip=#{remif[:addr]} --ServerApp.port=#{port} --ServerApp.token=#{token} --ServerApp.sock='"
    output, status = Open3.capture2e('ssh', 'gpu', cmd)
    $log.error(output) if status.exitstatus != 0
    next unless status.exitstatus == 0

    stdin, stdout, stderr, waiter = Open3.popen3('ssh', 'gpu')
    stdin.puts "tmux has-session -t jupyter; echo $?"
    r = IO.select([stdout], [], [], 3)
    if r.nil?
      $log.info 'tmux probe timed out'
      stdin.close
      waiter.kill
      next
    end
    if stdout.readline.to_i != 0
      $log.info 'tmux probe failed'
      stdin.close
      waiter.kill
      next
    end

    sleep 10
    probed_ok = false
    loop do
      $log.info 'doing TCP probe...' if not probed_ok
      begin
        Socket.tcp(remif[:addr], port, connect_timeout: 5) do |sock|
          sock.write("GET / HTTP/1.0\r\n\r\n")
          sock.flush
          r = IO.select([sock], [], [], 10)
          raise Errno::ETIMEDOUT.new if r.nil?
          line = sock.read_nonblock(1024)
          if line =~ /^HTTP[\/]1.[01] [0-9]+ [A-Za-z ]+\r\n/
            if not probed_ok
              $log.info 'probe ok!'
              $lock.synchronize do
                $state = :running
                $upstream = "#{remif[:addr]}:#{port}"
                $token = token
              end
              probed_ok = true
            end
          else
            raise 'bad response from server'
          end
        end
        if not waiter.alive?
          $log.info("ssh connection died but TCP is still working")
          stdin, stdout, stderr, waiter = Open3.popen3('ssh', 'gpu')
        end
      rescue Exception => e
        $log.info("TCP probe failed: #{e.inspect}")
        break if not waiter.alive?
      end
      stdin.puts "tmux has-session -t jupyter; echo $?"
      r = IO.select([stdout], [], [], 3)
      if r.nil?
        $log.info 'tmux probe timed out'
        break
      end
      if stdout.readline.to_i != 0
        $log.info 'tmux probe failed'
        break
      end
      sleep (probed_ok ? 30 : 10)
    end

    $lock.synchronize do
      $state = :dead
      $upstream = nil
      $token = nil
    end

    stdin.close
    stdout.close
    stderr.close
    waiter.kill
  end
end

class Application
  def call(env)
    req = Rack::Request.new(env)

    poke = false
    uri = req.get_header('HTTP_X_ORIGINAL_URI')
    poke = true if uri == '/' or uri =~ /^\/jupyter\/?$/
    poke = true if uri =~ /^\/jupyter\/lab\/?$/
    poke = true if uri =~ /^\/jupyter\/lab\/tree/

    info = $lock.synchronize do
      $lastreq = Time.now if poke
      {:state => $state, :upstream => $upstream, :token => $token}
    end
    $poke.signal if poke

    hdrs = {}
    hdrs['Content-Type'] = 'text/plain'
    hdrs['X-Upstream'] = info[:upstream] || '127.0.0.1:10'
    hdrs['X-Authz'] = info[:token] ? "token #{info[:token]}" : "none"
    hdrs['X-State'] = info[:state].to_s
    [200, hdrs, [info[:state].to_s, "\r\n"] ]
  end
end
