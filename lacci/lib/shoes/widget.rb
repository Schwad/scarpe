# frozen_string_literal: true

module Shoes
  # Shoes::Widget
  #
  # This is the display-service portable Shoes Widget interface. Visible Shoes
  # widgets like buttons inherit from this. Compound widgets made of multiple
  # different smaller Widgets inherit from it in their various apps or libraries.
  # The Shoes Widget helps build a Shoes-side widget tree, with parents and
  # children. Any API that applies to all widgets (e.g. remove) should be
  # defined here.
  #
  class Widget < Shoes::Linkable
    include Shoes::Log
    include Shoes::Colors

    class << self
      attr_accessor :widget_classes
      attr_accessor :widget_default_styles

      def inherited(subclass)
        Shoes::Widget.widget_classes ||= []
        Shoes::Widget.widget_classes << subclass

        Shoes::Widget.widget_default_styles ||= {}
        Shoes::Widget.widget_default_styles[subclass] = {}

        super
      end

      def dsl_name
        n = name.split("::").last.chomp("Widget")
        n.gsub(/(.)([A-Z])/, '\1_\2').downcase
      end

      def widget_class_by_name(name)
        widget_classes.detect { |k| k.dsl_name == name.to_s }
      end

      def validate_as(prop_name, value)
        prop_name = prop_name.to_s
        hashes = display_property_hashes

        h = hashes.detect { |hash| hash[:name] == prop_name }
        raise(Shoes::NoSuchStyleError, "Can't find property #{prop_name.inspect} in #{self} property list: #{hashes.inspect}!") unless h

        return value if h[:validator].nil?
        h[:validator].call(value)
      end

      private

      def linkable_properties
        @linkable_properties ||= []
      end

      def linkable_properties_hash
        @linkable_properties_hash ||= {}
      end

      public

      # Display properties in Shoes Linkables are automatically sync'd with the display side objects.
      # If a block is passed to display_property, that's the validation for the property. It should
      # convert a given value to a valid value for the property or throw an exception.
      def display_property(name, &validator)
        name = name.to_s

        return if linkable_properties_hash[name]

        linkable_properties << { name: name, validator: }
        linkable_properties_hash[name] = true
      end

      # Add these names as display properties
      def display_properties(*names)
        names.each { |n| display_property(n) }
      end

      def display_property_names
        parent_prop_names = self != Shoes::Widget ? self.superclass.display_property_names : []

        parent_prop_names | linkable_properties.map { |prop| prop[:name] }
      end

      def display_property_hashes
        parent_hashes = self != Shoes::Widget ? self.superclass.display_property_hashes : []

        parent_hashes + linkable_properties
      end

      def display_property_name?(name)
        linkable_properties_hash[name.to_s] ||
          (self != Shoes::Widget && superclass.display_property_name?(name))
      end
    end

    # Shoes uses a "hidden" style property for hide/show
    display_property :hidden

    def initialize(*args, **kwargs)
      log_init("Widget")

      default_styles = Shoes::Widget.widget_default_styles[self.class]

      self.class.display_property_names.each do |prop|
        prop_sym = prop.to_sym
        if kwargs[prop_sym]
          val = self.class.validate_as(prop, kwargs[prop_sym])
          instance_variable_set("@" + prop, val)
        elsif default_styles[prop_sym]
          val = self.class.validate_as(prop, default_styles[prop_sym])
          instance_variable_set("@" + prop, val)
        end
      end

      super() # linkable_id defaults to object_id
    end

    def inspect
      "#<#{self.class}:#{self.object_id} " +
        "@linkable_id=#{@linkable_id.inspect} @parent=#{@parent.inspect} " +
        "@children=#{@children.inspect} properties=#{display_property_values.inspect}>"
    end

    private

    def bind_self_event(event_name, &block)
      raise(Shoes::NoLinkableIdError, "Widget has no linkable_id! #{inspect}") unless linkable_id

      bind_shoes_event(event_name: event_name, target: linkable_id, &block)
    end

    def bind_no_target_event(event_name, &block)
      bind_shoes_event(event_name:, &block)
    end

    public

    def display_property_values
      all_property_names = self.class.display_property_names

      properties = {}
      all_property_names.each do |prop|
        properties[prop] = instance_variable_get("@" + prop)
      end
      properties["shoes_linkable_id"] = self.linkable_id
      properties
    end

    def style(*args, **kwargs)
      if args.empty? && kwargs.empty?
        # Just called as .style()
        display_property_values
      elsif args.empty?
        # This is called to set one or more Shoes styles (display properties.)
        prop_names = self.class.display_property_names
        unknown_styles = kwargs.keys.select { |k| !prop_names.include?(k.to_s) }
        unless unknown_styles.empty?
          raise Shoes::NoSuchStyleError, "Unknown styles for widget type #{self.class.name}: #{unknown_styles.join(", ")}"
        end

        kwargs.each do |name, val|
          instance_variable_set("@#{name}", val)
        end
      elsif args.length == 1 && args[0] < Shoes::Widget
        # Shoes supports calling .style with a Shoes class, e.g. .style(Shoes::Button, displace_left: 5)
        kwargs.each do |name, val|
          Shoes::Widget.widget_default_styles[args[0]][name.to_sym] = val
        end
      else
        raise Shoes::InvalidAttributeValueError, "Unexpected arguments to style! args: #{args.inspect}, keyword args: #{kwargs.inspect}"
      end
    end

    private

    def create_display_widget
      klass_name = self.class.name.delete_prefix("Scarpe::").delete_prefix("Shoes::")

      # Should we save a reference to widget for later reference?
      ::Shoes::DisplayService.display_service.create_display_widget_for(klass_name, self.linkable_id, display_property_values)
    end

    public

    attr_reader :parent

    def set_parent(new_parent)
      @parent&.remove_child(self)
      new_parent&.add_child(self)
      @parent = new_parent
      send_shoes_event(new_parent.linkable_id, event_name: "parent", target: linkable_id)
    end

    # Removes the element from the Shoes::Widget tree
    def destroy
      @parent&.remove_child(self)
      send_shoes_event(event_name: "destroy", target: linkable_id)
    end
    alias_method :remove, :destroy

    # Hide the widget.
    def hide
      self.hidden = true
    end

    # Show the widget.
    def show
      self.hidden = false
    end

    # Hide the widget if it is currently shown. Show it if it is currently hidden.
    def toggle
      self.hidden = !self.hidden
    end

    # We use method_missing for widget-creating methods like "button",
    # and also to auto-create display-property getters and setters.
    def method_missing(name, *args, **kwargs, &block)
      name_s = name.to_s

      if name_s[-1] == "="
        prop_name = name_s[0..-2]
        if self.class.display_property_name?(prop_name)
          self.class.define_method(name) do |new_value|
            raise Shoes::NoLinkableIdError, "Trying to set display properties in an object with no linkable ID!" unless linkable_id

            new_value = self.class.validate_as(prop_name, new_value)
            instance_variable_set("@" + prop_name, new_value)
            send_shoes_event({ prop_name => new_value }, event_name: "prop_change", target: linkable_id)
          end

          return self.send(name, *args, **kwargs, &block)
        end
      end

      if self.class.display_property_name?(name_s)
        self.class.define_method(name) do
          raise Shoes::NoLinkableIdError, "Trying to get display properties in an object with no linkable ID!" unless linkable_id

          instance_variable_get("@" + name_s)
        end

        return self.send(name, *args, **kwargs, &block)
      end

      klass = Widget.widget_class_by_name(name)
      return super unless klass

      ::Shoes::Widget.define_method(name) do |*args, **kwargs, &block|
        # Look up the Shoes widget and create it...
        widget_instance = klass.new(*args, **kwargs, &block)

        unless klass.ancestors.include?(Shoes::TextWidget)
          widget_instance.set_parent Shoes::App.instance.current_slot
        end

        widget_instance
      end

      send(name, *args, **kwargs, &block)
    end

    def respond_to_missing?(name, include_private = false)
      name_s = name.to_s
      return true if self.class.display_property_name?(name_s)
      return true if self.class.display_property_name?(name_s[0..-2]) && name_s[-1] == "="
      return true if Widget.widget_class_by_name(name_s)

      super
    end
  end
end
