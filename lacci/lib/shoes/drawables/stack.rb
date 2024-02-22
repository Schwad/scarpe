# frozen_string_literal: true

class Shoes
  class Stack < Shoes::Slot
    include Shoes::Background

    shoes_styles :scroll

    shoes_events # No Stack-specific events

    def initialize(*args, **kwargs, &block)
      super

      create_display_drawable

      # Create the display-side drawable *before* running the block.
      # Then child drawables have a parent to add themselves to.
      Shoes::App.instance.with_slot(self, &block) if block_given?
    end
  end
end
