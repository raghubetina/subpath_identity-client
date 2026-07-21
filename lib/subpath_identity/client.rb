# frozen_string_literal: true

require "subpath_identity"
require_relative "client/version"
require_relative "client/configuration"
require_relative "client/root_profile_client"
require_relative "client/revocation"
require_relative "client/sync_local_profile"

# For every app in a subpath_identity cluster that's a relying party —
# reads identity from the one app that owns it (see
# subpath_identity-provider), never mints its own user_id, and has no
# password of its own to check.
module SubpathIdentity
  module Client
    class Error < StandardError; end
  end
end
