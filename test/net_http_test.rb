require 'test_helper'
require 'semian/net_http'
require 'thin'

class TestNetHTTP < MiniTest::Unit::TestCase
  class RackServer
    def self.call(env)
      response_code = env['REQUEST_URI'].delete("/")
      response_code = '200' if response_code == ""
      [response_code, {'Content-Type' => 'text/html'}, ['Success']]
    end
  end

  PORT = 31_050
  TOXIC_PORT = PORT + 1

  DEFAULT_SEMIAN_OPTIONS = {
    tickets: 3,
    success_threshold: 1,
    error_threshold: 3,
    error_timeout: 10,
  }

  def test_semian_identifier
    with_server do
      Net::HTTP.start("localhost", TOXIC_PORT) do |http|
        assert_equal "http_localhost_#{TOXIC_PORT}", http.semian_identifier
      end
      Net::HTTP.start("127.0.0.1", TOXIC_PORT) do |http|
        assert_equal "http_127_0_0_1_#{TOXIC_PORT}", http.semian_identifier
      end
    end
  end

  def test_trigger_open
    with_semian_options do
      with_server do
        open_circuit!
        uri = URI("http://localhost:#{TOXIC_PORT}/200")
        assert_raises Net::CircuitOpenError do
          Net::HTTP.get(uri)
        end
      end
    end
  end

  def test_trigger_close_after_open
    with_semian_options do
      with_server do
        open_circuit!
        close_circuit!
      end
    end
  end

  def test_bulkheads_tickets_are_working
    with_semian_options do
      with_server do
        ticket_count = Net::HTTP.new("localhost", TOXIC_PORT).raw_semian_options[:tickets]

        m = Monitor.new
        tickets_all_used_cond = m.new_cond
        acquired_count = 0

        ticket_count.times do # acquire and sleep ticket_count threads
          threads << Thread.new do
            http = Net::HTTP.new("localhost", "#{TOXIC_PORT}")
            http.acquire_semian_resource(adapter: :nethttp, scope: :connection) do
              m.synchronize do
                acquired_count += 1
                tickets_all_used_cond.signal if acquired_count == ticket_count
              end
              sleep
            end
          end
        end

        Thread.new do
          tickets_all_used_cond.wait_until do # Wait until ticket_count tickets are held
            acquired_count == ticket_count
          end
          assert_raises Net::ResourceBusyError do
            Net::HTTP.get(URI("http://localhost:#{TOXIC_PORT}/"))
          end
          threads.each(&:join)
        end
      end
    end
  end

  def test_get_is_protected
    with_semian_options do
      with_server do
        open_circuit!
        assert_raises Net::CircuitOpenError do
          Net::HTTP.get(URI("http://localhost:#{TOXIC_PORT}/200"))
        end
      end
    end
  end

  def test_instance_get_is_protected
    with_semian_options do
      with_server do
        open_circuit!
        assert_raises Net::CircuitOpenError do
          http = Net::HTTP.new("localhost", "#{TOXIC_PORT}")
          http.get("/")
        end
      end
    end
  end

  def test_get_response_is_protected
    with_semian_options do
      with_server do
        open_circuit!
        assert_raises Net::CircuitOpenError do
          uri = URI("http://localhost:#{TOXIC_PORT}/200")
          Net::HTTP.get_response(uri)
        end
      end
    end
  end

  def test_post_form_is_protected
    with_semian_options do
      with_server do
        open_circuit!
        assert_raises Net::CircuitOpenError do
          uri = URI("http://localhost:#{TOXIC_PORT}/200")
          Net::HTTP.post_form(uri, 'q' => 'ruby', 'max' => '50')
        end
      end
    end
  end

  def test_http_start_method_is_protected
    with_semian_options do
      with_server do
        open_circuit!
        uri = URI("http://localhost:#{TOXIC_PORT}/200")
        assert_raises Net::CircuitOpenError do
          Net::HTTP.start(uri.host, uri.port) {}
        end
        close_circuit!
      end
    end
  end

  def test_http_action_request_inside_start_methods_are_protected
    with_semian_options do
      with_server do
        uri = URI("http://localhost:#{TOXIC_PORT}/200")
        Net::HTTP.start(uri.host, uri.port) do |http|
          open_circuit!
          get_subclasses(Net::HTTPRequest).each do |action|
            assert_raises(Net::CircuitOpenError, "#{action.name} did not raise a Net::CircuitOpenError") do
              request = action.new uri
              http.request(request)
            end
          end
        end
      end
    end
  end

  def test_custom_raw_semian_options_work_with_lookup
    with_server do
      semian_config = {}
      semian_config["development"] = {}
      semian_config["development"]["http_localhost_#{TOXIC_PORT}"] =
        {"tickets" => 1,
         "success_threshold" => 1,
         "error_threshold" => 3,
         "error_timeout" => 10}
      sample_env = "development"

      semian_options_proc = proc do |semian_identifier|
        semian_config[sample_env][semian_identifier]
      end

      with_semian_options(semian_options_proc) do
        Net::HTTP.start("localhost", TOXIC_PORT) do |http|
          assert_equal semian_config["development"][http.semian_identifier], http.raw_semian_options
        end
      end
    end
  end

  def test_custom_raw_semian_options_work_with_default_fallback
    with_server do
      semian_config = {}
      semian_config["development"] = {}
      semian_config["development"]["http_default"] =
        {"tickets" => 1,
         "success_threshold" => 1,
         "error_threshold" => 3,
         "error_timeout" => 10}
      sample_env = "development"

      semian_options_proc = proc do |semian_identifier|
        if !semian_config[sample_env].key?(semian_identifier)
          semian_config[sample_env]["http_default"]
        else
          semian_config[sample_env][semian_identifier]
        end
      end

      with_semian_options(semian_options_proc) do
        Net::HTTP.start("localhost", PORT) do |http|
          assert_equal semian_config["development"]["http_default"], http.raw_semian_options
          assert_equal semian_config["development"]["http_default"],
                       Semian::NetHTTP.retrieve_semian_options_by_identifier(http.semian_identifier)
        end
      end
    end
  end

  def test_custom_raw_semian_options_can_disable_using_nil
    with_server do
      semian_options_proc = proc { nil }
      with_semian_options(semian_options_proc) do
        http = Net::HTTP.new("localhost", "#{TOXIC_PORT}")
        assert_equal false, http.enabled?
      end
    end
  end

  def test_custom_raw_semian_options_can_disable_with_invalid_key
    with_server do
      semian_config = {}
      semian_config["development"] = {}
      semian_config["development"]["http_localhost_#{TOXIC_PORT}"] =
        {"tickets" => 1,
         "success_threshold" => 1,
         "error_threshold" => 3,
         "error_timeout" => 10}
      sample_env = "development"

      semian_options_proc = proc do |semian_identifier|
        semian_config[sample_env][semian_identifier]
      end
      with_semian_options(semian_options_proc) do
        http = Net::HTTP.new("localhost", "#{TOXIC_PORT}")
        assert_equal true, http.enabled?

        http = Net::HTTP.new("localhost", "#{TOXIC_PORT + 100}")
        assert_equal false, http.enabled?
      end
    end
  end

  def test_adding_custom_errors_do_trip_circuit
    with_semian_options do
      with_custom_errors([::OpenSSL::SSL::SSLError]) do
        with_server do
          http = Net::HTTP.new("localhost", TOXIC_PORT)
          http.use_ssl = true
          http.raw_semian_options[:error_threshold].times do
            assert_raises ::OpenSSL::SSL::SSLError do
              http.get("/200")
            end
          end
          assert_raises Net::CircuitOpenError do
            http.get("/200")
          end
        end
      end
    end
  end

  def test_multiple_different_endpoints_and_ports_are_tracked_differently
    with_semian_options do
      [PORT, PORT + 100].each do |port|
        reset_semian_resource(port: port)
      end
      with_server(ports: [PORT, PORT + 100], reset_semian_state: false) do |port|
        with_toxic(upstream_port: port, toxic_port: port + 1) do |name|
          Net::HTTP.get(URI("http://localhost:#{port + 1}/"))
          open_circuit!(toxic_port: port + 1, toxic_name: name)
          assert_raises Net::CircuitOpenError do
            Net::HTTP.get(URI("http://localhost:#{port + 1}/"))
          end
        end
      end
      with_server(ports: [PORT], reset_semian_state: false) do
        # different endpoint, should not raise errors even though localhost == 127.0.0.1
        Net::HTTP.get(URI("http://127.0.0.1:#{PORT + 1}/"))
      end
    end
  end

  def test_persistent_state_after_server_restart
    with_semian_options do
      port = PORT + 100
      with_server(ports: [port]) do
        with_toxic(upstream_port: port, toxic_port: port + 1) do |name|
          open_circuit!(toxic_port: port + 1, toxic_name: name)
        end
      end
      with_server(ports: [port], reset_semian_state: false) do
        with_toxic(upstream_port: port, toxic_port: port + 1) do |_|
          assert_raises Net::CircuitOpenError do
            Net::HTTP.get(URI("http://localhost:#{port + 1}/200"))
          end
        end
      end
    end
  end

  private

  def with_semian_options(options = DEFAULT_SEMIAN_OPTIONS)
    orig_semian_options = Semian::NetHTTP.raw_semian_options
    Semian::NetHTTP.raw_semian_options = options
    yield
  ensure
    Semian::NetHTTP.raw_semian_options = orig_semian_options
  end

  def with_custom_errors(errors)
    orig_errors = Semian::NetHTTP.exceptions
    Semian::NetHTTP.exceptions = Semian::NetHTTP::DEFAULT_ERRORS.dup + errors
    yield
  ensure
    Semian::NetHTTP.exceptions = orig_errors
  end

  def get_subclasses(klass)
    ObjectSpace.each_object(klass.singleton_class).to_a - [klass]
  end

  def open_circuit!(toxic_port: TOXIC_PORT, toxic_name: "semian_test_net_http")
    Net::HTTP.start("localhost", toxic_port) do |http|
      http.read_timeout = 0.1
      uri = URI("http://localhost:#{toxic_port}/200")
      http.raw_semian_options[:error_threshold].times do
        # Cause error error_threshold times so circuit opens
        Toxiproxy[toxic_name].downstream(:latency, latency: 150).apply do
          request = Net::HTTP::Get.new(uri)
          assert_raises Net::ReadTimeout do
            http.request(request)
          end
        end
      end
    end
  end

  def close_circuit!(toxic_port: TOXIC_PORT)
    http = Net::HTTP.new("localhost", toxic_port)
    Timecop.travel(http.raw_semian_options[:error_timeout])
    # Cause successes success_threshold times so circuit closes
    http.raw_semian_options[:success_threshold].times do
      response = http.get("/200")
      assert(200, response.code)
    end
  end

  def with_server(ports: [PORT], reset_semian_state: true)
    ports.each do |port|
      begin
        server_thread = Thread.new do
          Thin::Logging.silent = true
          Thin::Server.start('localhost', port, RackServer)
        end
        poll_until_ready(port: port)
        reset_semian_resource(port: port) if reset_semian_state
        @proxy = Toxiproxy[:semian_test_net_http]
        yield(port)
      ensure
        server_thread.kill
        poll_until_gone(port: port)
      end
    end
  end

  def reset_semian_resource(port:)
    Semian["http_localhost_#{port}"].reset if Semian["http_localhost_#{port}"]
    Semian["http_localhost_#{port + 1}"].reset if Semian["http_localhost_#{port + 1}"]
    Semian.destroy("http_localhost_#{port}")
    Semian.destroy("http_localhost_#{port + 1}")
  end

  def with_toxic(upstream_port: PORT, toxic_port: upstream_port + 1)
    old_proxy = @proxy
    name = "semian_test_net_http_#{upstream_port}_#{toxic_port}"
    Toxiproxy.populate([
      {
        name: name,
        upstream: "localhost:#{upstream_port}",
        listen: "localhost:#{toxic_port}",
      },
    ])
    @proxy = Toxiproxy[name]
    yield(name)
  rescue StandardError
  ensure
    @proxy = old_proxy
    begin
      Toxiproxy[name].destroy
    rescue StandardError
    end
  end

  def poll_until_ready(port: PORT, time_to_wait: 2)
    start_time = Time.now.to_i
    begin
      TCPSocket.new('127.0.0.1', port).close
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET
      if Time.now.to_i > start_time + time_to_wait
        raise "Couldn't reach the service on port #{port} after #{time_to_wait}s"
      else
        retry
      end
    end
  end

  def poll_until_gone(port: PORT, time_to_wait: 2)
    start_time = Time.now.to_i
    loop do
      if Time.now.to_i > start_time + time_to_wait
        raise "Could still reach the service on port #{port} after #{time_to_wait}s"
      end
      begin
        TCPSocket.new("127.0.0.1", port).close
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET
        return true
      end
    end
  end
end
