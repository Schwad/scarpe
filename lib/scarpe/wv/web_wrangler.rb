# frozen_string_literal: true

require "webview_ruby"
require "cgi"

# WebWrangler operates in multiple phases: setup and running.

# After creation, it starts in setup mode, and you can
# use setup-mode callbacks.

module Scarpe::Webview
  # The Scarpe WebWrangler, for Webview, manages a lot of Webviews quirks. It provides
  # a simpler underlying abstraction for DOMWrangler and the Webview drawables.
  # Webview can be picky - if you send it too many messages, it can crash. If the
  # messages you send it are too large, it can crash. If you don't return control
  # to its event loop, it can crash. It doesn't save references to all event handlers,
  # so if you don't save references to them, garbage collection will cause it to
  # crash.
  #
  # As well, Webview only supports asynchronous JS code evaluation with no value
  # being returned. One of WebWrangler's responsibilities is to make asynchronous
  # JS calls, detect when they return a value or time out, and make the result clear
  # to other Scarpe code.
  #
  # Some Webview API functions will crash on some platforms if called from a
  # background thread. Webview will halt all background threads when it runs its
  # event loop. So it's best to assume no Ruby background threads will be available
  # while Webview is running. If a Ruby app wants ongoing work to occur, that work
  # should be registered via a heartbeat handler on the Webview.
  #
  # A WebWrangler is initially in Setup mode, where the underlying Webview exists
  # but does not yet control the event loop. In Setup mode you can bind JS functions,
  # set up initialization code, but nothing is yet running.
  #
  # Once run() is called on WebWrangler, we will hand control of the event loop to
  # the Webview. This will also stop any background threads in Ruby.
  class WebWrangler
    include Shoes::Log

    # Whether Webview has been started. Once Webview is running you can't add new
    # Javascript bindings. Until it is running, you can't use eval to run Javascript.
    attr_reader :is_running

    # Once Webview is marked terminated, it's attempting to shut down. If we get
    # events (e.g. heartbeats) after that, we should ignore them.
    attr_reader :is_terminated

    # This is the time between heartbeats in seconds, usually fractional
    attr_reader :heartbeat

    # A reference to the control_interface that manages internal Scarpe Webview events.
    attr_reader :control_interface

    # This is the JS function name for eval results (internal-only)
    EVAL_RESULT = "scarpeAsyncEvalResult"

    # Allow this many seconds for Webview to finish our JS eval before we decide it's not going to
    EVAL_DEFAULT_TIMEOUT = 0.5

    # Create a new WebWrangler.
    #
    # @param title [String] window title
    # @param width [Integer] window width in pixels
    # @param height [Integer] window height in pixels
    # @param resizable [Boolean] whether the window should be resizable by the user
    # @param heartbeat [Float] time between heartbeats in seconds
    def initialize(title:, width:, height:, resizable: false, heartbeat: 0.1)
      log_init("Webview::WebWrangler")

      @log.debug("Creating WebWrangler...")

      # For now, always allow inspect element, so pass debug: true
      @webview = WebviewRuby::Webview.new debug: true
      @webview = Shoes::LoggedWrapper.new(@webview, "WebviewAPI") if ENV["SCARPE_DEBUG"]
      @init_refs = {} # Inits don't go away so keep a reference to them to prevent GC

      @title = title
      @width = width
      @height = height
      @resizable = resizable
      @heartbeat = heartbeat

      # JS setInterval uses RPC and is quite expensive. For many periodic operations
      # we can group them under a single heartbeat handler and avoid extra JS calls or RPC.
      @heartbeat_handlers = []

      # Need to keep track of which WebView Javascript evals are still pending,
      # what handlers to call when they return, etc.
      @pending_evals = {}
      @eval_counter = 0

      @dom_wrangler = DOMWrangler.new(self)

      bind("puts") do |*args|
        puts(*args)
      end

      @webview.bind(EVAL_RESULT) do |*results|
        receive_eval_result(*results)
      end

      # Ruby receives scarpeHeartbeat messages via the window library's main loop.
      # So this is a way for Ruby to be notified periodically, in time with that loop.
      @webview.bind("scarpeHeartbeat") do
        return unless @webview # I think GTK+ may continue to deliver events after shutdown

        periodic_js_callback
        @heartbeat_handlers.each(&:call)
        @control_interface.dispatch_event(:heartbeat)
      end
      js_interval = (heartbeat.to_f * 1_000.0).to_i
      @webview.init("setInterval(scarpeHeartbeat,#{js_interval})")
    end

    # Shorter name for better stack trace messages
    def inspect
      "Scarpe::WebWrangler:#{object_id}"
    end

    attr_writer :control_interface

    ### Setup-mode Callbacks

    # Bind a Javascript-callable function by name. When JS calls the function,
    # an async message is sent to Ruby via RPC and will eventually cause the
    # block to be called. This method only works in setup mode, before the
    # underlying Webview has been told to run.
    #
    # @param name [String] the Javascript name for the new function
    # @yield The Ruby block to be invoked when JS calls the function
    def bind(name, &block)
      raise Scarpe::JSBindingError, "App is running, javascript binding no longer works because it uses WebView init!" if @is_running

      @webview.bind(name, &block)
    end

    # Request that this block of code be run initially when the Webview is run.
    # This operates via #init and will not work if Webview is already running.
    #
    # @param name [String] the Javascript name for the init function
    # @yield The Ruby block to be invoked when Webview runs
    def init_code(name, &block)
      raise Scarpe::JSInitError, "App is running, javascript init no longer works!" if @is_running

      # Save a reference to the init string so that it doesn't get GC'd
      code_str = "#{name}();"
      @init_refs[name] = code_str

      bind(name, &block)
      @webview.init(code_str)
    end

    # Run the specified code periodically, every "interval" seconds.
    # If interval is unspecified, run per-heartbeat. This avoids extra
    # RPC and Javascript overhead. This may use the #init mechanism,
    # so it should be invoked when the WebWrangler is in setup mode,
    # before the Webview is running.
    #
    # TODO: add a way to stop this loop and unsubscribe.
    #
    # @param name [String] the name of the Javascript init function, if needed
    # @param interval [Float] the duration between invoking this block
    # @yield the Ruby block to invoke periodically
    def periodic_code(name, interval = heartbeat, &block)
      if interval == heartbeat
        @heartbeat_handlers << block
      else
        if @is_running
          # I *think* we need to use init because we want this done for every
          # new window. But will there ever be a new page/window? Can we just
          # use eval instead of init to set up a periodic handler and call it
          # good?
          raise Scarpe::PeriodicHandlerSetupError, "App is running, can't set up new periodic handlers with init!"
        end

        js_interval = (interval.to_f * 1_000.0).to_i
        code_str = "setInterval(#{name}, #{js_interval});"
        @init_refs[name] = code_str

        bind(name, &block)
        @webview.init(code_str)
      end
    end

    # Running callbacks

    # js_eventually is a native Webview JS evaluation. On syntax error, nothing happens.
    # On runtime error, execution stops at the error with no further
    # effect or notification. This is rarely what you want.
    # The js_eventually code is run asynchronously, returning neither error
    # nor value.
    #
    # This method does *not* return a promise, and there is no way to track
    # its progress or its success or failure.
    #
    # @param code [String] the Javascript code to attempt to execute
    # @return [void]
    def js_eventually(code)
      raise Scarpe::WebWranglerNotRunningError, "WebWrangler isn't running, eval doesn't work!" unless @is_running

      @log.warn "Deprecated: please do NOT use js_eventually, it's basically never what you want!" unless ENV["CI"]

      @webview.eval(code)
    end

    # Eval a chunk of JS code asynchronously. This method returns a
    # promise which will be fulfilled or rejected after the JS executes
    # or times out.
    #
    # We *both* care whether the JS has finished after it was
    # scheduled *and* whether it ever got scheduled at all. If it
    # depends on tasks that never fulfill or reject then it will
    # raise a timed-out exception.
    #
    # Right now we can't/don't pass arguments through from previous fulfilled
    # promises. To do that, you can schedule the JS to run after the
    # other promises succeed.
    #
    # Webview does not allow interacting with a JS eval once it has
    # been scheduled. So there is no way to guarantee that a piece of JS has
    # not executed, or will not execute in the future. A timeout exception
    # only means that WebWrangler will no longer wait for confirmation or
    # fulfill the promise if the JS later completes.
    #
    # @param code [String] the Javascript code to execute
    # @param timeout [Float] how long to allow before raising a timeout exception
    # @param wait_for [Array<Scarpe::Promise>] promises that must complete successfully before this JS is scheduled
    def eval_js_async(code, timeout: EVAL_DEFAULT_TIMEOUT, wait_for: [])
      unless @is_running
        raise Scarpe::WebWranglerNotRunningError, "WebWrangler isn't running, so evaluating JS won't work!"
      end

      this_eval_serial = @eval_counter
      @eval_counter += 1

      @pending_evals[this_eval_serial] = {
        id: this_eval_serial,
        code: code,
        start_time: Time.now,
        timeout_if_not_scheduled: Time.now + EVAL_DEFAULT_TIMEOUT,
      }

      # We'll need this inside the promise-scheduling block
      pending_evals = @pending_evals

      promise = Scarpe::Promise.new(parents: wait_for) do
        # Are we mid-shutdown?
        if @webview
          wrapped_code = WebWrangler.js_wrapped_code(code, this_eval_serial)

          # We've been scheduled!
          t_now = Time.now
          # Hard to be sure Webview keeps a proper reference to this, so we will
          pending_evals[this_eval_serial][:wrapped_code] = wrapped_code

          pending_evals[this_eval_serial][:scheduled_time] = t_now
          pending_evals[this_eval_serial].delete(:timeout_if_not_scheduled)

          pending_evals[this_eval_serial][:timeout_if_not_finished] = t_now + timeout
          @webview.eval(wrapped_code)
          @log.debug("Scheduled JS: (#{this_eval_serial})\n#{wrapped_code}")
        else
          # We're mid-shutdown. No more scheduling things.
          @log.warn "Mid-shutdown JS eval. Not scheduling JS!"
        end
      end

      @pending_evals[this_eval_serial][:promise] = promise

      promise
    end

    # This method takes a piece of Javascript code and wraps it in the WebWrangler
    # boilerplate to see if it parses successfully, run it, and see if it succeeds.
    # This function would normally be used by testing code, to mock Webview and
    # watch for code being run. Javascript code containing backticks
    # could potentially break this abstraction layer, which would cause the resulting
    # code to fail to parse and Webview would return no error. This should not be
    # used for random or untrusted code.
    #
    # @param code [String] the Javascript code to be wrapped
    # @param eval_id [Integer] the tracking code to use when calling EVAL_RESULT
    def self.js_wrapped_code(code, eval_id)
      <<~JS_CODE
        (function() {
          var code_string = #{JSON.dump code};
          try {
            result = eval(code_string);
            #{EVAL_RESULT}("success", #{eval_id}, result);
          } catch(error) {
            #{EVAL_RESULT}("error", #{eval_id}, error.message);
          }
        })();
      JS_CODE
    end

    private

    def periodic_js_callback
      time_out_eval_results
    end

    def receive_eval_result(r_type, id, val)
      entry = @pending_evals.delete(id)
      unless entry
        raise Scarpe::NonexistentEvalResultError, "Received an eval result for a nonexistent ID #{id.inspect}!"
      end

      @log.debug("Got JS value: #{r_type} / #{id} / #{val.inspect}")

      promise = entry[:promise]

      case r_type
      when "success"
        promise.fulfilled!(val)
      when "error"
        promise.rejected! Scarpe::JSRuntimeError.new(
          msg: "JS runtime error: #{val.inspect}!",
          code: entry[:code],
          ret_value: val,
        )
      else
        promise.rejected! Scarpe::JSInternalError.new(
          msg: "JS eval internal error! r_type: #{r_type.inspect}",
          code: entry[:code],
          ret_value: val,
        )
      end
    end

    # @todo would be good to keep 'tombstone' results for awhile after timeout, maybe up to around a minute,
    #   so we can detect if we're timing things out and then having them return successfully after a delay.
    #   Then we could adjust the timeouts. We could also check if later serial numbers have returned, and time
    #   out earlier serial numbers... *if* we're sure Webview will always execute JS evals in order.
    #   This all adds complexity, though. For now, do timeouts on a simple max duration.
    def time_out_eval_results
      t_now = Time.now
      timed_out_from_scheduling = @pending_evals.keys.select do |id|
        t = @pending_evals[id][:timeout_if_not_scheduled]
        t && t_now >= t
      end
      timed_out_from_finish = @pending_evals.keys.select do |id|
        t = @pending_evals[id][:timeout_if_not_finished]
        t && t_now >= t
      end
      timed_out_from_scheduling.each do |id|
        @log.debug("JS timed out because it was never scheduled: (#{id}) #{@pending_evals[id][:code].inspect}")
      end
      timed_out_from_finish.each do |id|
        @log.debug("JS timed out because it never finished: (#{id}) #{@pending_evals[id][:code].inspect}")
      end

      # A plus *should* be fine since nothing should ever be on both lists. But let's be safe.
      timed_out_ids = timed_out_from_scheduling | timed_out_from_finish

      timed_out_ids.each do |id|
        @log.error "Timing out JS eval! #{@pending_evals[id][:code]}"
        entry = @pending_evals.delete(id)
        err = Scarpe::JSTimeoutError.new(msg: "JS timeout error!", code: entry[:code], ret_value: nil)
        entry[:promise].rejected!(err)
      end
    end

    public

    attr_writer :empty_page

    # After setup, we call run to go to "running" mode.
    # No more setup callbacks should be called, only running callbacks.
    def run
      @log.debug("Run...")

      # From webview:
      # 0 - Width and height are default size
      # 1 - Width and height are minimum bounds
      # 2 - Width and height are maximum bounds
      # 3 - Window size can not be changed by a user
      hint = @resizable ? 0 : 3

      @webview.set_title(@title)
      @webview.set_size(@width, @height, hint)
      unless @empty_page
        raise Scarpe::EmptyPageNotSetError, "No empty page markup was set!"
      end

      @webview.navigate("data:text/html, #{CGI.escape @empty_page}")

      monkey_patch_console(@webview)

      @is_running = true
      @webview.run
      @is_running = false
      @webview.destroy
      @webview = nil
    end

    # Request destruction of WebWrangler, including terminating the underlying
    # Webview and (when possible) destroying it.
    def destroy
      @log.debug("Destroying WebWrangler...")
      @log.debug("  (WebWrangler was already terminated)") if @is_terminated
      @log.debug("  (WebWrangler was already destroyed)") unless @webview
      if @webview && !@is_terminated
        @bindings = {}
        @webview.terminate
        @is_terminated = true
      end
    end

    private

    # TODO: can this be an init()?
    def monkey_patch_console(window)
      # this forwards all console.log/info/error/warn calls also
      # to the terminal that is running the scarpe app
      window.eval <<~JS
        function patchConsole(fn) {
          const original = console[fn];
          console[fn] = function(...args) {
            original(...args);
            puts(...args);
          }
        };
        patchConsole('log');
        patchConsole('info');
        patchConsole('error');
        patchConsole('warn');
      JS
    end

    def empty
      Scarpe::Components::Calzini.empty_page_element
    end

    public

    # Replace the entire DOM - return a promise for when this has been done.
    # This will often get rid of smaller changes in the queue, which is
    # a good thing since they won't have to be run.
    #
    # @param html_text [String] The new HTML for the new full DOM
    # @return [Scarpe::Promise] a promise that will be fulfilled when the update is complete
    def replace(html_text)
      @dom_wrangler.request_replace(html_text)
    end

    # Request a DOM change - return a promise for when this has been done.
    # If a full replacement (see #replace) is requested, this change may
    # be lost. Only use it for changes that are preserved by a full update.
    #
    # @param js [String] the JS to execute to alter the DOM
    # @return [Scarpe::Promise] a promise that will be fulfilled when the update is complete
    def dom_change(js)
      @dom_wrangler.request_change(js)
    end

    # Return whether the DOM is, right this moment, confirmed to be fully
    # up to date or not.
    #
    # @return [Boolean] true if the window is fully updated, false if changes are pending
    def dom_fully_updated?
      @dom_wrangler.fully_updated?
    end

    # Return a promise that will be fulfilled when all current DOM changes
    # have committed. If other changes are requested before these
    # complete, the promise will ***not*** wait for them. If you wish to
    # wait until all changes from all sources have completed, use
    # #promise_dom_fully_updated.
    #
    # @return [Scarpe::Promise] a promise that will be fulfilled when all current changes complete
    def dom_promise_redraw
      @dom_wrangler.promise_redraw
    end

    # Return a promise which will be fulfilled the next time the DOM is
    # fully up to date. A slow trickle of changes can make this
    # take a long time, since it includes all current and future changes,
    # not just changes before this call.
    #
    # If you want to know that some specific individual change is done, it's often
    # easiest to use the promise returned by #dom_change, which will
    # be fulfilled when that specific change is verified complete.
    #
    # If no changes are pending, promise_dom_fully_updated will
    # return a promise that is already fulfilled.
    #
    # @return [Scarpe::Promise] a promise that will be fulfilled when all changes are complete
    def promise_dom_fully_updated
      @dom_wrangler.promise_fully_updated
    end

    # DOMWrangler will frequently schedule and confirm small JS updates.
    # A handler registered with on_every_redraw will be called after each
    # small update.
    #
    # @yield Called after each update or batch of updates is verified complete
    # @return [void]
    def on_every_redraw(&block)
      @dom_wrangler.on_every_redraw(&block)
    end
  end
end

class Scarpe::Webview::WebWrangler
  # Leaving DOM changes as "meh, async, we'll see when it happens" is terrible for testing.
  # Instead, we need to track whether particular changes have committed yet or not.
  # So we add a single gateway for all DOM changes, and we make sure its work is done
  # before we consider a redraw complete.
  #
  # DOMWrangler batches up changes into fewer RPC calls. It's fine to have a redraw
  # "in flight" and have changes waiting to catch the next bus. But we don't want more
  # than one in flight, since it seems like having too many pending RPC requests can
  # crash Webview. So we allow one redraw scheduled and one redraw promise waiting,
  # at maximum.
  #
  # A WebWrangler will create and wrap a DOMWrangler, serving as the interface
  # for all DOM operations.
  #
  # A batch of DOMWrangler changes may be removed if a full update is scheduled. That
  # update is considered to replace the previous incremental changes. Any changes that
  # need to execute even if a full update happens should be scheduled through
  # WebWrangler#eval_js_async, not DOMWrangler.
  class DOMWrangler
    include Shoes::Log

    # Changes that have not yet been executed
    attr_reader :waiting_changes

    # A Scarpe::Promise for JS that has been scheduled to execute but is not yet verified complete
    attr_reader :pending_redraw_promise

    # A Scarpe::Promise for waiting changes - it will be fulfilled when all waiting changes
    # have been verified complete, or when a full redraw that removed them has been
    # verified complete. If many small changes are scheduled, the same promise will be
    # returned for many of them.
    attr_reader :waiting_redraw_promise

    # Create a DOMWrangler that is paired with a WebWrangler. The WebWrangler is
    # treated as an underlying abstraction for reliable JS evaluation.
    def initialize(web_wrangler)
      log_init("Webview::WebWrangler::DOMWrangler")

      @wrangler = web_wrangler

      @waiting_changes = []
      @pending_redraw_promise = nil
      @waiting_redraw_promise = nil

      @fully_up_to_date_promise = nil

      # Initially we're waiting for a full replacement to happen.
      # It's possible to request updates/changes before we have
      # a DOM in place and before Webview is running. If we do
      # that, we should discard those updates.
      @first_draw_requested = false

      @redraw_handlers = []

      # The "fully up to date" logic is complicated and not
      # as well tested as I'd like. This makes it far less
      # likely that the event simply won't fire.
      # With more comprehensive testing, this should be
      # removable.
      web_wrangler.periodic_code("scarpeDOMWranglerHeartbeat") do
        if @fully_up_to_date_promise && fully_updated?
          @log.info("Fulfilling up-to-date promise on heartbeat")
          @fully_up_to_date_promise.fulfilled!
          @fully_up_to_date_promise = nil
        end
      end
    end

    def request_change(js_code)
      # No updates until there's something to update
      return unless @first_draw_requested

      @waiting_changes << js_code

      promise_redraw
    end

    def self.replacement_code(html_text)
      "document.getElementById('wrapper-wvroot').innerHTML = `#{html_text}`; true"
    end

    def request_replace(html_text)
      # Replace other pending changes, they're not needed any more
      @waiting_changes = [DOMWrangler.replacement_code(html_text)]
      @first_draw_requested = true

      @log.debug("Requesting DOM replacement...")
      promise_redraw
    end

    def on_every_redraw(&block)
      @redraw_handlers << block
    end

    # promise_redraw returns a Scarpe::Promise which will be fulfilled after all current
    # pending or waiting changes have completed. This may require creating a new
    # promise.
    #
    # What are the states of redraw?
    # "empty" - no waiting promise, no pending-redraw promise, no pending changes
    # "pending only" - no waiting promise, but we have a pending redraw with some changes; it hasn't committed yet
    # "pending and waiting" - we have a waiting promise for our unscheduled changes; we can add more unscheduled
    #     changes since we haven't scheduled them yet.
    #
    # This is often called after adding a new waiting change or replacing them, so the state may have just changed.
    # It can also be called when no changes have been made and no updates need to happen.
    def promise_redraw
      if fully_updated?
        # No changes to make, nothing in-process or waiting, so just return a pre-fulfilled promise
        @log.debug("Requesting redraw but there are no pending changes or promises, return pre-fulfilled")
        return ::Scarpe::Promise.fulfilled
      end

      # Already have a redraw requested *and* one on deck? Then all current changes will have committed
      # when we (eventually) fulfill the waiting_redraw_promise.
      if @waiting_redraw_promise
        @log.debug("Promising eventual redraw of #{@waiting_changes.size} waiting unscheduled changes.")
        return @waiting_redraw_promise
      end

      if @waiting_changes.empty?
        # There's no waiting_redraw_promise. There are no waiting changes. But we're not fully updated.
        # So there must be a redraw in flight, and we don't need to schedule a new waiting_redraw_promise.
        @log.debug("Returning in-flight redraw promise")
        return @pending_redraw_promise
      end

      @log.debug("Requesting redraw with #{@waiting_changes.size} waiting changes and no waiting promise - need to schedule something!")

      # We have at least one waiting change, possibly newly-added. We have no waiting_redraw_promise.
      # Do we already have a redraw in-flight?
      if @pending_redraw_promise
        # Yes we do. Schedule a new waiting promise. When it turns into the pending_redraw_promise it will
        # grab all waiting changes. In the mean time, it sits here and waits.
        #
        # We *could* do a fancy promise thing and have it update @waiting_changes for itself, etc, when it
        # schedules itself. But we should always be calling promise_redraw or having a redraw fulfilled (see below)
        # when these things change. I'd rather keep the logic in this method. It's easier to reason through
        # all the cases.
        @waiting_redraw_promise = ::Scarpe::Promise.new

        @log.debug("Creating a new waiting promise since a pending promise is already in place")
        return @waiting_redraw_promise
      end

      # We have no redraw in-flight and no pre-existing waiting line. The new change(s) are presumably right
      # after things were fully up-to-date. We can schedule them for immediate redraw.

      @log.debug("Requesting redraw with #{@waiting_changes.size} waiting changes - scheduling a new redraw for them!")
      promise = schedule_waiting_changes # This clears the waiting changes
      @pending_redraw_promise = promise

      promise.on_fulfilled do
        @redraw_handlers.each(&:call)
        @pending_redraw_promise = nil

        if @waiting_redraw_promise
          # While this redraw was in flight, more waiting changes got added and we made a promise
          # about when they'd complete. Now they get scheduled, and we'll fulfill the waiting
          # promise when that redraw finishes. Clear the old waiting promise. We'll add a new one
          # when/if more changes are scheduled during this redraw.
          old_waiting_promise = @waiting_redraw_promise
          @waiting_redraw_promise = nil

          @log.debug "Fulfilled redraw with #{@waiting_changes.size} waiting changes - scheduling a new redraw for them!"

          new_promise = promise_redraw
          new_promise.on_fulfilled { old_waiting_promise.fulfilled! }
        else
          # The in-flight redraw completed, and there's still no waiting promise. Good! That means
          # we should be fully up-to-date.
          @log.debug "Fulfilled redraw with no waiting changes - marking us as up to date!"
          if @waiting_changes.empty?
            # We're fully up to date! Fulfill the promise. Now we don't need it again until somebody asks
            # us for another.
            if @fully_up_to_date_promise
              @fully_up_to_date_promise.fulfilled!
              @fully_up_to_date_promise = nil
            end
          else
            @log.error "WHOAH, WHAT? My logic must be wrong, because there's " +
              "no waiting promise, but waiting changes!"
          end
        end

        @log.debug("Redraw is now fully up-to-date") if fully_updated?
      end.on_rejected do
        begin
          
        rescue Scarpe::JSRuntimeError => e
          @log.error "JS runtime error: #{e.full_message}"
        rescue Scarpe::JSRedrawError => e
          @log.error "JS Redraw failed: #{e.full_message}"
        end
        # @log.error "Could not complete JS redraw! #{promise.reason.full_message}"
        # @log.debug("REDRAW FULLY UP TO DATE BUT JS FAILED") if fully_updated?

        # raise Scarpe::JSRedrawError, "JS Redraw failed! Bailing!"

        # Later we should figure out how to handle this. Clear the promises and queues and request another redraw?
      end
    end

    def fully_updated?
      @pending_redraw_promise.nil? && @waiting_redraw_promise.nil? && @waiting_changes.empty?
    end

    # Return a promise which will be fulfilled when the DOM is fully up-to-date
    def promise_fully_updated
      if fully_updated?
        # No changes to make, nothing in-process or waiting, so just return a pre-fulfilled promise
        return ::Scarpe::Promise.fulfilled
      end

      # Do we already have a promise for this? Return it. Everybody can share one.
      if @fully_up_to_date_promise
        return @fully_up_to_date_promise
      end

      # We're not fully updated, so we need a promise. Create it, return it.
      @fully_up_to_date_promise = ::Scarpe::Promise.new
    end

    private

    # Put together the waiting changes into a new in-flight redraw request.
    # Return it as a promise.
    def schedule_waiting_changes
      return if @waiting_changes.empty?

      js_code = @waiting_changes.join(";")
      @waiting_changes = [] # They're not waiting any more!
      @wrangler.eval_js_async(js_code)
    end
  end

  # An ElementWrangler provides a way for a Drawable to manipulate is DOM element(s)
  # via their HTML IDs. The most straightforward Drawables can have a single HTML ID
  # and use a single ElementWrangler to make any needed changes.
  #
  # For now we don't need an ElementWrangler to add DOM elements, just to manipulate them
  # after initial render. New DOM objects for Drawables are normally added via full
  # redraws rather than incremental updates.
  #
  # Any changes made via ElementWrangler may be cancelled if a full redraw occurs,
  # since it is assumed that small DOM manipulations are no longer needed. If a
  # change would need to be made even if a full redraw occurred, it should be
  # scheduled via WebWrangler#eval_js_async, not via an ElementWrangler.
  class ElementWrangler
    attr_reader :html_id

    # Create an ElementWrangler for the given HTML ID or selector.
    # The caller should provide exactly one of the html_id or selector.
    #
    # @param html_id [String] the HTML ID for the DOM element
    def initialize(html_id: nil, selector: nil, multi: false)
      @webwrangler = ::Scarpe::Webview::DisplayService.instance.wrangler
      raise Scarpe::MissingWranglerError, "Can't get WebWrangler!" unless @webwrangler

      if html_id && !selector
        @selector = "document.getElementById('" + html_id + "')"
      elsif selector && !html_id
        @selector = selector
      else
        raise ArgumentError, "Must provide exactly one of html_id or selector!"
      end

      @multi = multi
    end

    private

    def on_each(fragment)
      if @multi
        @webwrangler.dom_change("a = Array.from(#{@selector}); a.forEach((item) => item#{fragment}); true")
      else
        @webwrangler.dom_change(@selector + fragment + ";true")
      end
    end

    public

    # Return a promise that will be fulfilled when all changes scheduled via
    # this ElementWrangler are verified complete.
    #
    # @return [Scarpe::Promise] a promise that will be fulfilled when scheduled changes are complete
    def promise_update
      @webwrangler.dom_promise_redraw
    end

    # Update the JS DOM element's value. The given Ruby value will be converted to string and assigned in backquotes.
    #
    # @param new_value [String] the new value
    # @return [Scarpe::Promise] a promise that will be fulfilled when the change is complete
    def value=(new_value)
      on_each(".value = `" + new_value + "`")
    end

    # Update the JS DOM element's inner_text. The given Ruby value will be converted to string and assigned in single-quotes.
    #
    # @param new_text [String] the new inner_text
    # @return [Scarpe::Promise] a promise that will be fulfilled when the change is complete
    def inner_text=(new_text)
      on_each(".innerText = '" + new_text + "'")
    end

    # Update the JS DOM element's inner_html. The given Ruby value will be converted to string and assigned in backquotes.
    #
    # @param new_html [String] the new inner_html
    # @return [Scarpe::Promise] a promise that will be fulfilled when the change is complete
    def inner_html=(new_html)
      on_each(".innerHTML = `" + new_html + "`")
    end

    # Update the JS DOM element's outer_html. The given Ruby value will be converted to string and assigned in backquotes.
    #
    # @param new_html [String] the new outer_html
    # @return [Scarpe::Promise] a promise that will be fulfilled when the change is complete
    def outer_html=(new_html)
      on_each(".outerHTML = `" + new_html + "`")
    end

    # Update the JS DOM element's attribute. The given Ruby value will be inspected and assigned.
    #
    # @param attribute [String] the attribute name
    # @param value [String] the new attribute value
    # @return [Scarpe::Promise] a promise that will be fulfilled when the change is complete
    def set_attribute(attribute, value)
      on_each(".setAttribute(" + attribute.inspect + "," + value.inspect + ")")
    end

    # Update an attribute of the JS DOM element's style. The given Ruby value will be inspected and assigned.
    #
    # @param style_attr [String] the style attribute name
    # @param value [String] the new style attribute value
    # @return [Scarpe::Promise] a promise that will be fulfilled when the change is complete
    def set_style(style_attr, value)
      on_each(".style.#{style_attr} = " + value.inspect + ";")
    end

    # Remove the specified DOM element
    #
    # @return [Scarpe::Promise] a promise that wil be fulfilled when the element is removed
    def remove
      on_each(".remove()")
    end

    def toggle_input_button(mark)
      checked_value = mark ? "true" : "false"
      on_each(".checked = #{checked_value}")
    end
  end
end
