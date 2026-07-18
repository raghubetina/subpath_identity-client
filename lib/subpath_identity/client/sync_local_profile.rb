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
    # (the staleness signal) — plus whatever else sync_remote_profile
    # populates. See subpath_identity_client:install for a generator
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
          remote = RootProfileClient.fetch(cookies[SubpathIdentity.config.cookie_name])
          return revoke_local_identity(profile) if remote == RootProfileClient::GONE

          profile = upsert_local_profile(model, remote) if remote
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
      # If the losing side of that race is holding a row that reflects
      # an earlier fetch than the one that just ran, the cache_key
      # comparison below brings it back in line with what was just
      # fetched, rather than leaving it stuck on stale data.
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
