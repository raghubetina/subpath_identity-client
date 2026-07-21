class LocalProfile < ApplicationRecord
  # No uniqueness validation alongside the DB's own unique index on
  # global_user_id — SubpathIdentity::Client::SyncLocalProfile relies on
  # create_or_find_by rescuing the database's uniqueness violation when
  # two first-visits from the same user race to insert a row. A
  # uniqueness validation here would catch the race first and raise
  # ActiveRecord::RecordInvalid instead, which create_or_find_by doesn't
  # rescue — Rails' own docs call this out as the wrong combination.
  validates :global_user_id, presence: true

  # SyncLocalProfile sets revoked_at to tombstone a gone account and
  # blanks every other (cached-profile) column. If you add columns with
  # NOT NULL constraints, give them a default or make them nullable, so
  # revocation can blank them.
end
