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
end
