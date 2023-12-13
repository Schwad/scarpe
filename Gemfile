# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in scarpe.gemspec
gemspec

gem "lacci", path: "lacci"
gem "scarpe-components", path: "scarpe-components"

gem "bloops", "~> 0.5" #path: "../bloopsaphone" #git: "https://github.com/scarpe-team/bloopsaphone"
gem "rake", "~> 13.0"

group :test do
  gem "minitest", "~> 5.0"
  gem "minitest-reporters"
end

group :development do
  gem "yard"
  gem "redcarpet"
  gem "debug"
  gem "rubocop", "~> 1.21"
  gem "htmlbeautifier"
  gem "diff-lcs"
  #gem "commonmarker"
  #gem "github-markup"
end
