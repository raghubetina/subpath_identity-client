# frozen_string_literal: true

require "active_support/concern"

module SubpathIdentity
  module Client
    # Include in ApplicationController, after SubpathIdentity::ControllerHelpers.
    #
    # No-op when signed out. When signed in, find_or_creates a row in
    # SubpathIdentity.config.local_profile_model keyed by the shared
    # user_id — this app never authenticates anyone, so there's no
    # password to check, just a local cache of whatever profile fields
    # SubpathIdentity.config.sync_remote_profile decides to keep — and
    # refreshes it from the identity provider's API only when the
    # cookie's cache_key claim has moved past what's stored locally. The
    # provider being briefly unreachable degrades to "use what's
    # cached," not an error: current_local_profile can be nil even while
    # signed_in? is true.
    #
    # The local model needs exactly two columns this gem manages
    # directly — global_user_id (the identity link) and root_cache_key
    # (the staleness signal: the provider's authoritative cache key, see
    # upsert_local_profile) — plus whatever else sync_remote_profile
    # populates. Include SubpathIdentity::ControllerHelpers first: this
    # concern uses its write_shared_identity and clear_shared_identity. See subpath_identity_client:install for a generator
    # that scaffolds both the migration and a starting model.
    module SyncLocalProfile
      extend ActiveSupport::Concern

      included do
        before_action :sync_local_profile
        helper_method :current_local_profile if respond_to?(:helper_method)
      end

      def current_local_profile
        @current_local_profile
      end

      private

      def sync_local_profile
        return unless signed_in?

        model = SubpathIdentity.config.local_profile_model
        profile = model.find_by(global_user_id: current_shared_identity[:user_id])

        # A tombstone (revoked_at set) is permanent — account ids never
        # reuse, so "gone" is gone. Re-assert the revocation without
        # fetching, so a browser that still carries a valid cookie for a
        # since-closed account stays signed out cluster-wide instead of
        # displaying a cached profile.
        return revoke_local_identity(profile) if profile&.revoked_at

        if profile.nil? || profile.root_cache_key != current_shared_identity[:cache_key]
          remote = RootProfileClient.fetch(
            cookies[SubpathIdentity.config.cookie_name],
            expected_user_id: current_shared_identity[:user_id]
          )
          return revoke_local_identity(profile) if remote == RootProfileClient::GONE

          if remote
            profile = upsert_local_profile(model, remote)
            # upsert returns nil when it finds a tombstone: an older
            # in-flight success resuming after a newer revocation (a
            # closed the account, b's 410 already tombstoned the row).
            # It must not resurrect the closed account — apply the
            # revocation instead of the stale profile.
            return revoke_local_identity(model.find_by(global_user_id: current_shared_identity[:user_id])) if profile.nil?

            # Reissue THIS browser's cookie with the provider's
            # authoritative cache key, so the next request compares
            # equal and skips the fetch. The local row is shared by
            # every browser this user has, so it alone can't record
            # which version each browser has seen — without the cookie
            # rewrite, two browsers holding different still-valid claims
            # make the row oscillate: each request overwrites the row to
            # its own claim and forces the other browser to refetch,
            # every time, forever. With it, each stale browser pays for
            # exactly one fetch and converges. Safe against lifetime
            # extension: write_shared_identity preserves the identity's
            # absolute deadline (core >= 0.5) unless explicitly renewed,
            # which this deliberately never does.
            if remote[:cache_key] != current_shared_identity[:cache_key]
              write_shared_identity(cache_key: remote[:cache_key])
            end
          end
        end
        @current_local_profile = profile
      end

      # The provider gave a definitive "no valid account for this
      # identity" (a closed or deleted account — GONE, not a transient
      # nil). Turn the row into a TOMBSTONE (revoked_at set, cached
      # profile columns nulled) rather than deleting it, and clear the
      # shared identity cookie, which (being Path=/) signs the account
      # out across every app in the cluster on its next request.
      #
      # Why a tombstone and not destroy!: the provider fetch has no
      # per-user lock, so an OLDER in-flight success can resume after a
      # NEWER revocation. If revocation just deleted the row, that stale
      # success would create_or_find_by a fresh row and resurrect the
      # closed account. The tombstone is a persistent "this id is gone"
      # marker that upsert_local_profile refuses to overwrite, so result
      # order can't undo a revocation. Account ids never reuse, so the
      # tombstone is safe to keep forever.
      #
      # Nulling the profile columns also erases the cached PII (email,
      # name, ...) at revocation — the row's non-managed columns exist
      # only to cache profile data, so blanking all of them is
      # column-name-agnostic. (There is still a hard-to-hit residual: a
      # success whose save! lands in the microsecond after this update!
      # could re-populate columns; a row lock would close it, overkill
      # for this cache. The reported deterministic ordering is fixed.)
      def revoke_local_identity(profile)
        profile ||= SubpathIdentity.config.local_profile_model
          .create_or_find_by(global_user_id: current_shared_identity[:user_id])
        profile.assign_attributes(tombstone_attributes(profile))
        profile.save!
        clear_shared_identity
        @current_local_profile = nil
      end

      # global_user_id links identity, revoked_at is the tombstone
      # marker, the pk and timestamps are ActiveRecord's — everything
      # else on the row is cached profile data to blank.
      TOMBSTONE_KEEP = %w[id global_user_id revoked_at created_at updated_at].freeze
      private_constant :TOMBSTONE_KEEP

      def tombstone_attributes(profile)
        blanked = (profile.attributes.keys - TOMBSTONE_KEEP).to_h { |col| [col, nil] }
        blanked.merge("revoked_at" => Time.now)
      end

      # Two first-visits from the same user can both find no local row
      # and both try to insert one — create_or_find_by rescues the
      # database's unique-index violation and re-finds instead of
      # letting the losing request's insert raise. That only works if
      # the local model has no uniqueness validation alongside its
      # unique index (a validation would catch the duplicate first and
      # raise ActiveRecord::RecordInvalid before the database-level
      # rescue ever gets a chance to run — see the generated model for
      # why there isn't one).
      #
      # root_cache_key records the PROVIDER's authoritative cache key —
      # the version of the data actually held. The requesting browser's
      # cookie is brought up to the same value by the reissue in
      # sync_local_profile, which is what makes the local-vs-cookie
      # comparison converge for every browser (an earlier attempt stored
      # the requesting cookie's claim instead, which converged for one
      # browser but made two browsers with different still-valid claims
      # oscillate the row on alternating requests).
      # Returns nil when it finds a tombstone — the caller applies the
      # revocation instead of the stale profile (see sync_local_profile).
      def upsert_local_profile(model, remote)
        sync_block = SubpathIdentity.config.sync_remote_profile
        profile = model.create_or_find_by(global_user_id: current_shared_identity[:user_id]) do |record|
          record.root_cache_key = remote[:cache_key]
          sync_block&.call(record, remote)
        end
        return nil if profile.revoked_at

        if profile.root_cache_key != remote[:cache_key]
          profile.root_cache_key = remote[:cache_key]
          sync_block&.call(profile, remote)
          profile.save!
        end
        profile
      end
    end
  end
end
