# frozen_string_literal: true

source "https://rubygems.org"

# Not yet on RubyGems.org, so point Bundler at the GitHub source here —
# a path: to a sibling checkout only resolves on a machine that happens
# to have core checked out next door, which is why this gem's own CI
# (and anyone else's clone) couldn't `bundle install`. Remove once
# subpath_identity has a real release and the gemspec dependency resolves
# from RubyGems normally.
gem "subpath_identity", github: "raghubetina/subpath_identity"

# Specify your gem's dependencies in subpath_identity-client.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

gem "minitest", "~> 5.16"

gem "standard", "~> 1.3"

group :test do
  gem "actionpack", ">= 8.1"
  gem "sqlite3", ">= 2.0"
  gem "railties", ">= 8.1"
end
