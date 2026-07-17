# frozen_string_literal: true

source "https://rubygems.org"

# Local sibling checkout, not yet published — remove once subpath_identity
# has a real release on RubyGems.org and this can resolve normally.
gem "subpath_identity", path: "../subpath_identity"

# Specify your gem's dependencies in subpath_identity-client.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

gem "minitest", "~> 5.16"

gem "standard", "~> 1.3"

group :test do
  gem "actionpack", ">= 7.0"
  gem "sqlite3", ">= 2.0"
  gem "railties", ">= 7.0"
end
