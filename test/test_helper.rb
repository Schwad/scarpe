# frozen_string_literal: true

RUBY_MAIN_OBJ = self

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "scarpe"

require "tempfile"
require "json"
require "fileutils"

require "minitest/autorun"

require "minitest/reporters"
Minitest::Reporters.use! [Minitest::Reporters::SpecReporter.new]

# Soon this should go in the framework, not here
unless Object.constants.include?(:Shoes)
  Shoes = Scarpe
end

# Docs for our Webview lib: https://github.com/Maaarcocr/webview_ruby

class ScarpeTest < Minitest::Test
  def with_tempfile(prefix, contents)
    t = Tempfile.new(prefix)
    t.write(contents)
    t.flush # Make sure the contents are written out

    yield(t.path)
  ensure
    t.close
    t.unlink
  end

  # Temporarily set env vars for the block of code inside
  def with_env_vars(envs)
    old_env = {}
    envs.each do |k, v|
      old_env[k] = ENV[k]
      ENV[k] = v
    end
    yield
  ensure
    old_env.each { |k, v| ENV[k] = v }
  end

  SCARPE_EXE = File.expand_path("../exe/scarpe", __dir__)
  TEST_OPTS = [:timeout, :allow_fail, :allow_timeout, :debug, :exit_immediately]

  def run_test_scarpe_code(scarpe_app_code, test_code: "", test_name: nil, **opts)
    test_name ||= caller_locations[0].label

    bad_opts = opts.keys - TEST_OPTS
    raise "Bad options passed to run_test_scarpe_code: #{bad_opts.inspect}!" unless bad_opts.empty?

    with_tempfile("scarpe_test_app.rb", scarpe_app_code) do |test_app_location|
      run_test_scarpe_app(test_app_location, test_code:, test_name:, **opts)
    end
  end

  LOGGER_DIR = File.expand_path("#{__dir__}/../logger")
  # Using an instance variable doesn't work for ALREADY_SET_UP(etc) and I'm not sure why not
  ALREADY_SET_UP_TEST_FAILURES = { setup: false }
  TEST_SCARPE_LOG_CONFIG = File.expand_path("#{LOGGER_DIR}/scarpe_wv_test.json")
  log_out = JSON.load_file(TEST_SCARPE_LOG_CONFIG).values.map { |_level, locs| locs }
  TEST_SAVE_FILES = log_out.select { |s| s.start_with?("logger/") }.map { |s| s.gsub(%r{\Alogger\/}, "") }
  def set_up_test_failures
    return if ALREADY_SET_UP_TEST_FAILURES[:setup]

    ALREADY_SET_UP_TEST_FAILURES[:setup] = true
    # Delete stale test failures, if any, before starting test run
    Dir["#{LOGGER_DIR}/test_failure*.log"].each { |fn| File.unlink(fn) }

    Minitest.after_run do
      # Remove un-saved test logs
      TEST_SAVE_FILES.each do |f|
        path = "#{LOGGER_DIR}/#{f}"
        File.unlink(path) if File.exist?(path)
      end

      # Print test failure logs to console for CI
      unless Dir["#{LOGGER_DIR}/test_failure*_out.log"].empty?
        puts "Some tests have failed! See #{LOGGER_DIR}/test_failure*_out.log for test logs!"
      end
    end
  end

  def logfail_out_loc(filepath, test_name:)
    dir, filename = File.split(filepath)
    all_exts = filename.split(".", 2)[1]
    base = File.basename(filename, "." + all_exts)

    "#{dir}/#{base}_#{test_name}_out.#{all_exts}"
  end

  def save_failure_logs(test_name:)
    TEST_SAVE_FILES.each do |log_file|
      full_loc = File.expand_path("#{LOGGER_DIR}/#{log_file}")
      log_out_spot = logfail_out_loc(full_loc, test_name:)
      next unless File.exist?(full_loc)

      FileUtils.mv full_loc, log_out_spot
    end
  end

  def run_test_scarpe_app(test_app_location, test_name: nil, test_code: "", **opts)
    test_name ||= caller_locations[0].label

    bad_opts = opts.keys - TEST_OPTS
    raise "Bad options passed to run_test_scarpe_app: #{bad_opts.inspect}!" unless bad_opts.empty?

    set_up_test_failures

    with_tempfile("scarpe_test_results.json", "") do |result_path|
      do_debug = opts[:debug] ? true : false
      timeout = opts[:timeout] ? opts[:timeout].to_f : 1.5
      scarpe_test_code = <<~SCARPE_TEST_CODE
        require "scarpe/wv/control_interface_test"

        override_app_opts debug: #{do_debug}

        on_event(:init) do
          die_after #{timeout}

          # scarpeStatusAndExit is barbaric, and ignores all pending assertions and other subtleties.
          wrangler.bind("scarpeStatusAndExit") do |*results|
            return_results(results)
            app.destroy
          end
        end
      SCARPE_TEST_CODE

      scarpe_test_code += test_code

      if opts[:exit_immediately]
        scarpe_test_code += <<~TEST_EXIT_IMMEDIATELY
          on_event(:next_heartbeat) do
            app.destroy
          end
        TEST_EXIT_IMMEDIATELY
      end

      # Remove old results, if any
      File.unlink(result_path)

      with_tempfile("scarpe_control.rb", scarpe_test_code) do |control_file_path|
        # Start the application using the exe/scarpe utility
        system("SCARPE_TEST_CONTROL=#{control_file_path} SCARPE_TEST_RESULTS=#{result_path} " +
          "SCARPE_LOG_CONFIG=\"#{TEST_SCARPE_LOG_CONFIG}\" " +
          "ruby #{SCARPE_EXE} --dev #{test_app_location}")

        # Check if the process exited normally or crashed (segfault, failure, timeout)
        if $?.exitstatus != 0
          save_failure_logs(test_name:)
          assert(false, "Scarpe app crashed with exit code: #{$?.exitstatus}")
          return
        end
      end

      # If failure is okay, don't check for status or assertions
      return if opts[:allow_fail]

      # If we exit immediately with no result written, that's fine.
      # But if we wrote a result, make sure it says pass, not fail.
      return if opts[:exit_immediately] && !File.exist?(result_path)

      unless File.exist?(result_path)
        save_failure_logs(test_name:)
        assert(false, "Scarpe app returned no status code!")
        return
      end

      begin
        out_data = JSON.parse File.read(result_path)

        unless out_data.respond_to?(:each) && out_data.length > 1
          raise "Scarpe app returned an unexpected data format! #{out_data.inspect}"
        end

        # If we exit immediately we still need a results file and a true value.
        # We were getting exit_immediately being fine with apps segfaulting,
        # so we need to check.
        if opts[:exit_immediately]
          if out_data[0]
            # That's all we needed!
            return
          end

          save_failure_logs(test_name:)
          assert false, "App exited immediately, but its results were false! #{out_data.inspect}"
        end

        unless out_data[0]
          puts JSON.pretty_generate(out_data[1])
          save_failure_logs(test_name:)
          assert false, "Some Scarpe tests failed..."
        end

        if out_data[1].is_a?(Hash)
          test_data = out_data[1]
          test_data["succeeded"].times { assert true } # Add to the number of assertions
          test_data["failures"].each { |failure| assert false, "Failed Scarpe app test: #{failure}" }
          if test_data["still_pending"] != 0
            save_failure_logs(test_name:)
            assert false, "Some tests were still pending!"
          end
        end
      rescue
        $stderr.puts "Error parsing JSON data for Scarpe test status!"
        raise
      end
    end
  end

  def assert_html(actual_html, expected_tag, **opts, &block)
    expected_html = Scarpe::HTML.render do |h|
      h.public_send(expected_tag, opts, &block)
    end

    assert_equal expected_html, actual_html
  end
end
