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
    # A NOT NULL cached column with a default, plus a presence
    # validation below — the exact schema shape that broke the old
    # nulling-based revocation. Revocation deletes the row now, so
    # neither trips it.
    t.string :display_name, null: false, default: "Anonymous"
    t.timestamps
  end
  add_index :local_profiles, :global_user_id, unique: true

  create_table :subpath_identity_client_revocations, force: true do |t|
    t.integer :global_user_id, null: false
    t.timestamps
  end
  add_index :subpath_identity_client_revocations, :global_user_id, unique: true

  # An inbound foreign key onto local_profiles with no cascade and no
  # dependent: wiring — the host-extension shape that blocks
  # revocation's row DELETE with ActiveRecord::InvalidForeignKey.
  # Revocation must fail closed around it: cookie cleared, marker kept,
  # failure reported rather than raised.
  create_table :profile_notes, force: true do |t|
    t.references :local_profile, null: false, foreign_key: true
    t.string :body
  end
end

class LocalProfile < ActiveRecord::Base
  validates :global_user_id, presence: true
  validates :display_name, presence: true
end

class ProfileNote < ActiveRecord::Base
  belongs_to :local_profile
end
