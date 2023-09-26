# frozen_string_literal: true

require "scarpe/components/base64"

module Scarpe::Webview
  class Image < Widget
    include Scarpe::Components::Base64

    def initialize(properties)
      super

      @url = valid_url?(@url) ? @url : "data:image/png;base64,#{encode_file_to_base64(@url)}"
    end

    def element
      render("image")
    end
  end
end
