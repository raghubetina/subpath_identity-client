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
        if profile.nil? || profile.root_cache_key != current_shared_identity[:cache_key]
          remote = RootProfileClient.fetch(
            cookies[SubpathIdentity.config.cookie_name],
            expected_user_id: current_shared_identity[:user_id]
          )
          return revoke_local_identity(profile) if remote == RootProfileClient::GONE

          if remote
            profile = upsert_local_profile(model, remote)
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
            # absolute deadline (core >= 0.4) unless explicitly renewed,
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
      # nil). Drop the cached copy of its profile and clear the shared
      # identity cookie, which (being Path=/) signs the account out
      # across every app in the cluster on its next request, not just
      # here.
      #
      # Bounded, deliberately: this only fires when a fetch actually
      # happens — i.e. on a cache_key mismatch. While the cookie's
      # cache_key still matches the local row, no fetch occurs (that's
      # the whole point of the cache_key), so a closure made elsewhere
      # that doesn't re-encode this visitor's cookie isn't noticed until
      # something does force a fetch, or until the cookie hits its own
      # TTL — and the cached row's columns (email, name, ...) persist in
      # this app's own database until then regardless. The shared cookie
      # TTL bounds *display*, not *retention*; see the README. Closing
      # that window would mean re-validating on every request, defeating
      # the cache. clear_shared_identity comes from
      # SubpathIdentity::ControllerHelpers (include it first).
      #
      # destroy!, not destroy: a model callback that aborts the delete
      # should surface loudly on a revocation path, not be swallowed into
      # "we said we revoked but the PII row is still there."
      def revoke_local_identity(profile)
        profile&.destroy!
        clear_shared_identity
        @current_local_profile = nil
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
      def upsert_local_profile(model, remote)
        sync_block = SubpathIdentity.config.sync_remote_profile
        profile = model.create_or_find_by(global_user_id: current_shared_identity[:user_id]) do |record|
          record.root_cache_key = remote[:cache_key]
          sync_block&.call(record, remote)
        end
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
