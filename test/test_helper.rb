# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "subpath_identity/client"
require "active_record"
require "sqlite3"
require "action_controller"
require "rails/generators/test_case"

require "minitest/autorun"

# A plain ":memory:" database gives every pooled connection its own
# private, empty database — fine for a single-threaded test, but the
# concurrency test below checks out a second connection from a second
# thread, which would see no schema at all and blow up before it ever
# reaches the assertions. The shared-cache URI form makes every
# connection opened by this process see the same in-memory database.
ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: "file::memory:?cache=shared",
  flags: SQLite3::Constants::Open::READWRITE | SQLite3::Constants::Open::CREATE |
    SQLite3::Constants::Open::URI | SQLite3::Constants::Open::SHAREDCACHE,
  pool: 5
)
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :local_profiles, force: true do |t|
    t.integer :global_user_id, null: false
    t.string :root_cache_key
    t.string :email
    t.datetime :revoked_at
    t.timestamps
  end
  add_index :local_profiles, :global_user_id, unique: true
end

class LocalProfile < ActiveRecord::Base
  validates :global_user_id, presence: true
end
