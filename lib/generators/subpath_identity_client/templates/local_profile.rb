class LocalProfile < ApplicationRecord
  # No uniqueness validation alongside the DB's own unique index on
  # global_user_id — SubpathIdentity::Client::SyncLocalProfile relies on
  # create_or_find_by rescuing the database's uniqueness violation when
  # two first-visits from the same user race to insert a row. A
  # uniqueness validation here would catch the race first and raise
  # ActiveRecord::RecordInvalid instead, which create_or_find_by doesn't
  # rescue — Rails' own docs call this out as the wrong combination.
  validates :global_user_id, presence: true

  # Add whatever profile columns you want to cache (email, name, ...).
  # SyncLocalProfile deletes this row on revocation — it never nulls
  # your columns — so NOT NULL constraints and presence validations on
  # them are fine.
  #
  # That revocation-time delete is a plain DELETE (no callbacks, no
  # dependent: handling), so if you add tables that reference this one,
  # declare their foreign keys on_delete: :cascade — or override
  # remove_local_profile_rows in your controller for cleanup a cascade
  # can't express. See "What revocation assumes about your schema" in
  # this gem's README.
end
