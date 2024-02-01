# frozen_string_literal: true

class Shoes
  class App < Shoes::Drawable
    include Shoes::Log

    class << self
      attr_accessor :instance
    end

    # The Shoes root of the drawable tree
    attr_reader :document_root

    # The application directory for this app. Often this will be the directory
    # containing the launched application file.
    attr_reader :dir

    shoes_styles :title, :width, :height, :resizable, :features

    # This is defined to avoid the linkable-id check in the Shoes-style method_missing def'n
    def features
      @features
    end

    CUSTOM_EVENT_LOOP_TYPES = ["displaylib", "return", "wait"]

    init_args
    def initialize(
      title: "Shoes!",
      width: 480,
      height: 420,
      resizable: true,
      features: [],
      &app_code_body
    )
      log_init("Shoes::App")

      if Shoes::App.instance
        @log.error("Trying to create a second Shoes::App in the same process! Fail!")
        raise Shoes::Errors::TooManyInstancesError, "Cannot create multiple Shoes::App objects!"
      else
        Shoes::App.instance = self
      end

      # We cd to the app's containing dir when running the app
      @dir = Dir.pwd

      @do_shutdown = false
      @event_loop_type = "displaylib" # the default

      @features = features

      unknown_ext = features - Shoes::FEATURES - Shoes::EXTENSIONS
      unsupported_features = unknown_ext & Shoes::KNOWN_FEATURES
      unless unsupported_features.empty?
        @log.error("Shoes app requires feature(s) not supported by this display service: #{unsupported_features.inspect}!")
        raise Shoes::Errors::UnsupportedFeatureError, "Shoes app needs features: #{unsupported_features.inspect}"
      end
      unless unknown_ext.empty?
        @log.warn("Shoes app requested unknown features #{unknown_ext.inspect}! Known: #{(Shoes::FEATURES + Shoes::EXTENSIONS).inspect}")
      end

      @slots = []

      super

      # This creates the DocumentRoot, including its corresponding display drawable
      @document_root = Shoes::DocumentRoot.new

      # Now create the App display drawable
      create_display_drawable

      # Set up testing *after* Display Service basic objects exist

      if ENV["SHOES_SPEC_TEST"]
        test_code = File.read ENV["SHOES_SPEC_TEST"]
        unless test_code.empty?
          Shoes::Spec.instance.run_shoes_spec_test_code test_code
        end
      end

      @app_code_body = app_code_body

      # Try to de-dup as much as possible and not send repeat or multiple
      # destroy events
      @watch_for_destroy = bind_shoes_event(event_name: "destroy") do
        Shoes::DisplayService.unsub_from_events(@watch_for_destroy) if @watch_for_destroy
        @watch_for_destroy = nil
        self.destroy(send_event: false)
      end

      @watch_for_event_loop = bind_shoes_event(event_name: "custom_event_loop") do |loop_type|
        raise(Shoes::Errors::InvalidAttributeValueError, "Unknown event loop type: #{loop_type.inspect}!") unless CUSTOM_EVENT_LOOP_TYPES.include?(loop_type)

        @event_loop_type = loop_type
      end

      Signal.trap("INT") do
        @log.warn("App interrupted by signal, stopping...")
        puts "\nStopping Shoes app..."
        destroy
      end
    end

    def init
      send_shoes_event(event_name: "init")
      return if @do_shutdown

      ::Shoes::App.instance.with_slot(@document_root, &@app_code_body)
    end

    # "Container" drawables like flows, stacks, masks and the document root
    # are considered "slots" in Shoes parlance. When a new slot is created,
    # we push it here in order to track what drawables are found in that slot.
    def push_slot(slot)
      @slots.push(slot)
    end

    def pop_slot
      return if @slots.size <= 1

      @slots.pop
    end

    def current_slot
      @slots[-1]
    end

    def with_slot(slot_item, &block)
      return unless block_given?

      push_slot(slot_item)
      Shoes::App.instance.instance_eval(&block)
    ensure
      pop_slot
    end

    # We use method_missing for drawable-creating methods like "button".
    # The parent's method_missing will auto-create Shoes style getters and setters.
    # This is similar to the method_missing in Shoes::Slot, but different in
    # where the new drawable appears.
    def method_missing(name, *args, **kwargs, &block)
      klass = ::Shoes::Drawable.drawable_class_by_name(name)
      return super unless klass

      ::Shoes::App.define_method(name) do |*args, **kwargs, &block|
        klass.new(*args, **kwargs, &block)
      end

      send(name, *args, **kwargs, &block)
    end

    # Get the current draw context for the current slot
    #
    # @return [Hash] a hash of Shoes styles for the current draw context
    def current_draw_context
      current_slot&.current_draw_context
    end

    # This usually doesn't return. The display service may take control
    # of the main thread. Local Webview even stops any background threads.
    # However, some display libraries don't want to shut down and don't
    # want to (and/or can't) take control of the event loop.
    def run
      if @do_shutdown
        $stderr.puts "Destroy has already been signaled, but we just called Shoes::App.run!"
        return
      end

      # The display lib can send us an event to customise the event loop handling.
      # But it must do so before the "run" event returns.
      send_shoes_event(event_name: "run")

      case @event_loop_type
      when "wait"
        # Display lib wants us to busy-wait instead of it.
        until @do_shutdown
          Shoes::DisplayService.dispatch_event("heartbeat", nil)
        end
      when "displaylib"
        # If run event returned, that means we're done.
        destroy
      when "return"
        # We can just return to the main event loop. But we shouldn't call destroy.
        # Presumably some event loop *outside* our event loop is handling things.
      else
        raise Shoes::Errors::InvalidAttributeValueError, "Internal error! Incorrect event loop type: #{@event_loop_type.inspect}!"
      end
    end

    def destroy(send_event: true)
      @do_shutdown = true
      send_shoes_event(event_name: "destroy") if send_event
    end

    def all_drawables
      out = []

      to_add = [@document_root, @document_root.children]
      until to_add.empty?
        out.concat(to_add)
        to_add = to_add.flat_map { |w| w.respond_to?(:children) ? w.children : [] }.compact
      end

      out
    end

    # We can add various ways to find drawables here.
    # These are sort of like Shoes selectors, used for testing.
    def find_drawables_by(*specs)
      drawables = all_drawables
      specs.each do |spec|
        if spec == Shoes::App
          drawables = [Shoes::App.instance]
        elsif spec.is_a?(Class)
          drawables.select! { |w| spec === w }
        elsif spec.is_a?(Symbol) || spec.is_a?(String)
          s = spec.to_s
          case s[0]
          when "$"
            begin
              # I'm not finding a global_variable_get or similar...
              global_value = eval s
              drawables &= [global_value]
            rescue
              raise Shoes::Errors::InvalidAttributeValueError, "Error getting global variable: #{spec.inspect}"
            end
          when "@"
            if Shoes::App.instance.instance_variables.include?(spec.to_sym)
              drawables &= [self.instance_variable_get(spec)]
            else
              raise Shoes::Errors::InvalidAttributeValueError, "Can't find top-level instance variable: #{spec.inspect}!"
            end
          else
            if s.start_with?("id:")
              find_id = Integer(s[3..-1])
              drawable = Shoes::Drawable.drawable_by_id(find_id)
              drawables &= [drawable]
            else
              raise Shoes::Errors::InvalidAttributeValueError, "Don't know how to find drawables by #{spec.inspect}!"
            end
          end
        else
          raise(Shoes::Errors::InvalidAttributeValueError, "Don't know how to find drawables by #{spec.inspect}!")
        end
      end
      drawables
    end
  end
end

# Event handler DSLs get defined in both App and Slot - same code, slightly different results
events = [:motion, :hover, :leave, :click, :release, :keypress, :animate, :every, :timer]
events.each do |event|
  Shoes::App.define_method(event) do |*args, &block|
    subscription_item(args:, shoes_api_name: event.to_s, &block)
  end
  Shoes::Slot.define_method(event) do |*args, &block|
    subscription_item(args:, shoes_api_name: event.to_s, &block)
  end
end

# These methods will need to be defined on Slots too, but probably need a rework in general.
class Shoes::App < Shoes::Drawable
  # This is going to go away. See issue #496
  def background(...)
    current_slot.background(...)
  end

  # This is going to go away. See issue #498
  def border(...)
    current_slot.border(...)
  end

  # Draw Context methods -- forward to the current slot
  [:fill, :nofill, :stroke, :strokewidth, :nostroke, :rotate].each do |dc_method|
    define_method(dc_method) do |*args|
      current_slot.send(dc_method, *args)
    end
  end

  # Shape DSL methods

  def move_to(x, y)
    raise(Shoes::Errors::InvalidAttributeValueError, "Pass only Numeric arguments to move_to!") unless x.is_a?(Numeric) && y.is_a?(Numeric)

    if current_slot.is_a?(::Shoes::Shape)
      current_slot.add_shape_command(["move_to", x, y])
    end
  end

  def line_to(x, y)
    raise(Shoes::Errors::InvalidAttributeValueError, "Pass only Numeric arguments to line_to!") unless x.is_a?(Numeric) && y.is_a?(Numeric)

    if current_slot.is_a?(::Shoes::Shape)
      current_slot.add_shape_command(["line_to", x, y])
    end
  end

  # Not implemented yet: curve_to, arc_to

  alias_method :info, :puts
end
