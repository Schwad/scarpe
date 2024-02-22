# frozen_string_literal: true

class Shoes
  class Flow < Shoes::Slot
    include Shoes::Background

    Shoes::Drawable.drawable_default_styles[Shoes::Flow][:width] = "100%"

    shoes_events

    def initialize(*args, **kwargs, &block)
      super

      # Create the display-side drawable *before* instance_eval, which will add child drawables with their display drawables
      create_display_drawable

      Shoes::App.instance.with_slot(self, &block) if block_given?
    end
  end
end
