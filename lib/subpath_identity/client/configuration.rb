# frozen_string_literal: true

module SubpathIdentity
  # Reopened here, not defined here — SubpathIdentity::Configuration
  # itself lives in the subpath_identity gem. These are the config knobs
  # only a relying-party (client) app needs: where to find the
  # identity-owning app, and how to sync its profile response into a
  # local cache.
  class Configuration
    attr_writer :root_origin_env_var, :internal_profile_path, :local_profile_model

    def root_origin_env_var
      @root_origin_env_var ||= "ROOT_ORIGIN"
    end

    def internal_profile_path
      @internal_profile_path ||= "/internal/me"
    end

    def root_origin
      ENV.fetch(root_origin_env_var, "localhost:3000")
    end

    def local_profile_model
      @local_profile_model || raise(
        "SubpathIdentity.config.local_profile_model is not set — configure it to your local " \
        "profile-cache model (e.g. config.local_profile_model = LocalProfile) in " \
        "config/initializers/subpath_identity.rb"
      )
    end

    # A block called with (local_profile_record, remote_hash) whenever
    # SyncLocalProfile refreshes the local cache from the identity
    # provider's response — the app's own choice of which remote fields
    # to keep locally.
    def sync_remote_profile(&block)
      if block
        @sync_remote_profile_block = block
      else
        @sync_remote_profile_block
      end
    end
  end
end
