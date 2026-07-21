# frozen_string_literal: true

require "active_record"

module SubpathIdentity
  module Client
    # A gem-owned marker table: one row per global_user_id the provider
    # has reported gone. Deliberately separate from the host's
    # local-profile model.
    #
    # Two reasons it can't live as a column on that model. First, a
    # marker has to be insertable no matter what the host's profile
    # schema requires — a NOT NULL column or a presence validation on a
    # cached field would otherwise turn a first-visit revocation into a
    # 500, and blanking such a column on update would too. Second, the
    # marker has to OUTLIVE the profile row: revocation deletes the row
    # (a plain DELETE erases the cached PII with no null-constraint
    # hazard), and a stale in-flight success that recreates the row must
    # not be able to resurrect the account — the durable marker in this
    # separate table is what a later request checks to reap that row and
    # stay signed out. Account ids never reuse, so a marker is permanent.
    class Revocation < ActiveRecord::Base
      self.table_name = "subpath_identity_client_revocations"
    end
  end
end
