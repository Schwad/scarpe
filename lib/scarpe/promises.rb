# Funny thing... We need promises as an API concept since we have a JS event
# loop doing its thing, and we need to respond to actions that it takes.
# But there's not really a Ruby implementation of Promises *without* an
# attached form of concurrency. So here we are, writing our own :-/
#
# In theory you could probably write some kind of "no-op thread pool"
# for the ruby-concurrency gem, pass it manually to every promise we
# created and then raise an exception any time we tried to do something
# in the background. That's probably more code than writing our own, though,
# and we'd be fighting it constantly.
#
# This class is inspired by concurrent-ruby [Promise](https://ruby-concurrency.github.io/concurrent-ruby/1.1.5/Concurrent/Promise.html)
# which is inspired by Javascript Promises, which is what we actually need
# for our use case. We can't easily tell when our WebView begins processing
# our request, which removes the :processing state. This can be used for
# executing JS, but also generally waiting on events.
#
# We don't fully control ordering here, so it *is* conceivable that a
# child waiting on a parent can be randomly fulfilled, even if we didn't
# expect it. We don't consider that an error. Similarly, we'll call
# on_scheduled callbacks if a promise is fulfilled, even though we
# never explicitly scheduled it. If a promise is *rejected* without
# ever being scheduled, we won't call those callbacks.

class Scarpe
  class Promise
    PROMISE_STATES = [:unscheduled, :pending, :fulfilled, :rejected]

    def self.debug
      @debug
    end

    def self.debug=(val)
      @debug = val
    end

    attr_reader :state
    attr_reader :parents
    attr_reader :returned_value
    attr_reader :reason

    # These methods are meant to be a prettier interface to promises,
    # suitable for day-to-day usage.

    # Create a promise and then instantly fulfill it.
    def self.fulfilled(return_val = nil, parents: [], &block)
      p = Promise.new(parents: parents, &block)
      p.fulfilled!(return_val)
      p
    end

    # Create a promise and then instantly reject it.
    def self.rejected(reason = nil, parents: [])
      p = Promise.new(parents: parents)
      p.rejected!(reason)
    end

    # Instance methods

    # This is one way to return a value directly from a schedule block,
    # which also fulfills the promise.
    #
    # This syntax is somewhat awkward, to work around the fact that
    # we're often not scheduling Ruby, so return values from a
    # scheduling block aren't usually what we want. When the scheduling
    # block is run, the calculation has started, not finished.
    #def return_final_value(val)
    #  fulfilled!(val)
    #end

    def fulfilled!(value = nil)
      set_state(:fulfilled, value)
    end

    def rejected!(reason = nil)
      set_state(:rejected, reason)
    end

    def then(&block)
      # Create a new promise. It's waiting on us. It runs the
      # specified code when scheduled.
      Promise.new(parents: [self], &block)
    end

    # The Promise.new method, along with all the various handlers,
    # are pretty raw. They'll do what promises do, but they're not
    # the prettiest. However, they ensure that guarantees are made
    # and so on, so they're great as plumbing under the syntactic
    # sugar above.

    def initialize(state: nil, parents: [], &scheduler)
      # These are as initially specified, and effectively immutable
      @state = state
      @parents = parents

      # These are what we're waiting on, and will be
      # removed as time goes forward.
      @waiting_on = parents.select { |p| !p.complete? }
      @on_fulfilled = []
      @on_rejected = []
      @on_scheduled = []
      @scheduler = scheduler
      @executor = nil
      @returned_value = nil
      @reason = nil

      if complete?
        # Did we start out already fulfilled or rejected?
        # If so, we can skip a lot of fiddly checking.
        # Don't need a scheduler or to care about parents
        # or anything.
        @waiting_on = []
        @scheduler = nil
      elsif @state == :pending
        # Did we get an explicit :pending? Then we don't need
        # to schedule ourselves, or care about the scheduler
        # in general.
        @scheduler = nil
      elsif @state.nil? || @state == :unscheduled
        # If no state was given or we're unscheduled, we'll
        # wait until our parents have all completed to
        # schedule ourselves.

        if @waiting_on.empty?
          # No further dependencies, we can schedule ourselves
          @state = :pending

          # We have no on_scheduled handlers yet, but this will
          # call and clear the scheduler.
          call_handlers_for(:pending)
        else
          # We're still waiting on somebody, no scheduling yet
          @state = :unscheduled
          @waiting_on.each do |dep|
            dep.on_fulfilled { parent_fulfilled!(dep) }
            dep.on_rejected { parent_rejected!(dep) }
          end
        end
      end
    end

    def complete?
      @state == :fulfilled || @state == :rejected
    end

    # These promises are mostly designed for external execution.
    # You could put together your own thread-pool, or use RPC,
    # a WebView, a database or similar source of external calculation.
    # But in some cases, sure, it's reasonable to execute locally.
    # In those cases, you can register an executor, which will be
    # called when the promise is ready to execute but has not yet
    # done so. Registering an executor on a promise that is
    # already fulfilled is an error. Registering an executor on
    # a promise that has already rejected is a no-op.
    def to_execute(&block)
      case @state
      when :fulfilled
        # Should this be a no-op instead?
        raise "Registering an executor on an already fulfilled promise means it will never run!"
      when :rejected
        return
      when :unscheduled
        @executor = block # save for later
      when :pending
        @executor = block
        call_executor
      else
        raise "Internal error, illegal state!"
      end

      self
    end

    private

    # set_state looks at the old and new states of the promise. It calls handlers and updates tracking
    # data accordingly.
    def set_state(new_state, value_or_reason = nil)
      old_state = @state

      # First, filter out illegal input
      unless PROMISE_STATES.include?(old_state)
        raise "Internal Promise error! Internal state was #{old_state.inspect}! Legal states: #{PROMISE_STATES.inspect}"
      end
      unless PROMISE_STATES.include?(new_state)
        raise "Internal Promise error! Internal state was set to #{new_state.inspect}! Legal states: #{PROMISE_STATES.inspect}"
      end
      if new_state != :fulfilled && new_state != :rejected && !value_or_reason.nil?
        raise "Internal promise error! Non-completed state transitions should not specify a value or reason!"
      end

      # Here's our state-transition grid for what we're doing here.
      # "From" state is on the left, "to" state is on top.
      #
      #    U P F R
      #
      # U  - 1 . .
      # P  X - . .
      # F  X X - X
      # R  X X X -
      #
      # -  Change from same to same, no effect
      # X  Illegal for one reason or another, raise error
      # .  Great, no problem, run handlers but not @scheduler or @executor
      # 1  Interesting case - if we have an executor, actually change to a *different* state instead

      # Transitioning from our state to our same state? No-op.
      return if new_state == old_state

      # Transitioning to any *different* state after being fulfilled or rejected? Nope. Those states are final.
      if complete?
        raise "Internal Promise error! Trying to change state from #{old_state.inspect} to #{new_state.inspect}!"
      end

      if old_state == :pending && new_state == :unscheduled
        raise "Can't change state from :pending to :unscheduled! Scheduling is not reversible!"
      end

      # The next three checks should all be followed by calling handlers for the newly-changed state.
      # See call_handlers_for below.

      # Okay, we're getting scheduled.
      if old_state == :unscheduled && new_state == :pending
        @state = new_state
        call_handlers_for(new_state)

        # It's not impossible for the scheduler to do something that fulfills or rejects the promise.
        # In that case it *also* called the appropriate handlers. Let's get out of here.
        return if @state == :fulfilled || @state == :rejected

        if @executor
          # In this case we're still pending, but we have a synchronous executor. Let's do it.
          call_executor
        end

        return
      end

      # Setting to rejected calls the rejected handlers. But no scheduling ever occurs, so on_scheduled handlers
      # will never be called.
      if new_state == :rejected
        @state = :rejected
        @reason = value_or_reason
        call_handlers_for(new_state)
      end

      # If we go straight from :unscheduled to :fulfilled we *will* run the on_scheduled callbacks,
      # because we pretend the scheduling *did* occur at some point. Normally that'll be no callbacks,
      # of course.
      #
      # Fun-but-unfortunate trivia: you *can* fulfill a promise before all its parents are fulfilled.
      # If you do, the unfinished parents will result in nil arguments to the on_fulfilled handler,
      # because we have no other value to provide. The scheduler callback will never be called, but
      # the on_scheduled callbacks, if any, will be.
      if new_state == :fulfilled
        @state = :fulfilled
        @returned_value = value_or_reason
        call_handlers_for(new_state)
      end
    end

    # This private method calls handlers for a new state, removing those handlers
    # since they have now been called. This interacts subtly with set_state()
    # above, particularly in the case of fulfilling a promise without it ever being
    # properly scheduled.
    #
    # The rejected handlers will be cleared if the promise is fulfilled and vice-versa.
    # After rejection, no on_fulfilled handler should ever be called and vice-versa.
    #
    # When we go from :unscheduled to :pending, the scheduler, if any, should be
    # called and cleared. That should *not* happen when going from :unscheduled to
    # :fulfilled.
    def call_handlers_for(state)
      case state
      when :fulfilled
        @on_scheduled.each { |h| h.call(*@parents.map(&:returned_value)) }
        @on_fulfilled.each { |h| h.call(*@parents.map(&:returned_value)) }
        @on_fulfilled = @on_rejected = @on_fulfilled = []
        @scheduler = @executor = nil
      when :rejected
        @on_rejected.each { |h| h.call(*@parents.map(&:returned_value)) }
        @on_fulfilled = @on_scheduled = @on_rejected = []
        @scheduler = @executor = nil
      when :pending
        # A scheduler can get an exception. If so, treat it as rejection
        # and the exception as the provided reason.
        if @scheduler
          begin
            @scheduler.call(*@parents.map(&:returned_value))
          rescue => e
            if Promise.debug
              puts "Error while running scheduler! #{e.full_message}"
            end
            rejected!(e)
          end
          @scheduler = nil
        end
        @on_scheduled.each { |h| h.call(*@parents.map(&:returned_value)) }
        @on_scheduled = []
      else
        raise "Internal error! Trying to call handlers for #{state.inspect}!"
      end
    end

    def parent_fulfilled!(parent)
      @waiting_on.delete(parent)

      # Last parent? If so, schedule ourselves.
      if @waiting_on.empty? && !self.complete?
        # This will result in :pending if there's no executor,
        # or fulfilled/rejected if there is an executor.
        set_state(:pending)
      end
    end

    def parent_rejected!(parent)
      @waiting_on = []

      unless self.complete?
        # If our parent was rejected and we were waiting on them,
        # now we're rejected too.
        set_state(:rejected)
      end
    end

    def call_executor
      raise("Internal error! Should not call_executor with no executor!") unless @executor

      begin
        result = @executor.call(*@parents.map(&:returned_value))
        fulfilled!(result)
      rescue => e
        if Promise.debug
          puts "Error running executor! #{e.full_message}"
        end
        rejected!(e)
        return
      end

    ensure
      @executor = nil
    end

    public

    def on_fulfilled(&handler)
      unless handler
        raise "You must pass a block to on_fulfilled!"
      end
      case @state
      when :fulfilled
        handler.call(*@parents.map(&:returned_value))
      when :pending, :unscheduled
        @on_fulfilled << handler
      when :rejected
        # Do nothing
      end

      self
    end

    def on_rejected(&handler)
      unless handler
        raise "You must pass a block to on_rejected!"
      end

      case @state
      when :rejected
        handler.call(*@parents.map(&:returned_value))
      when :pending, :unscheduled
        @on_rejected << handler
      when :fulfilled
        # Do nothing
      end

      self
    end

    def on_scheduled(&handler)
      unless handler
        raise "You must pass a block to on_scheduled!"
      end

      # Add a pending handler or call it now
      case @state
      when :fulfilled, :pending
        handler.call(*@parents.map(&:returned_value))
      when :unscheduled
        @on_scheduled << handler
      when :rejected
        # Do nothing
      end

      self
    end
  end
end
