# frozen_string_literal: true

if RUBY_VERSION[0..2] < "3.2"
  $stderr.puts "Scarpe requires Ruby 3.2 or higher!"
  exit(-1)
end

require "securerandom"
require "json"

require_relative "scarpe/version"
require_relative "scarpe/promises"
require_relative "scarpe/display_service"
require_relative "scarpe/widgets"

# WebView Display Service
require_relative "scarpe/wv"

class Scarpe
  class << self
    def app(...)
      app = Scarpe::App.new(...)
      app.init
      app.run
      app.destroy
    end
  end
end
