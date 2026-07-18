# frozen_string_literal: true

require "net/http"
require "json"
require "cgi/escape"
require "active_support/core_ext/object/blank"

module SubpathIdentity
  module Client
    # Calls the identity-owning app's internal profile endpoint (see
    # subpath_identity-provider's README for the expected shape),
    # proving identity by forwarding the same shared identity cookie
    # value the caller already has — the provider decodes it exactly the
    # way it decodes every other request. Any failure (origin down,
    # timeout, malformed response) returns nil rather than raising: a
    # stale or missing local profile cache is a degraded page, not a 500.
    module RootProfileClient
      # Returned by fetch when the provider gives a *definitive*, typed
      # "this identity resolves to no valid account" answer: HTTP 410
      # Gone with a JSON body of {"error": "account_gone"} — a closed or
      # deleted account, or an unknown user_id. Distinct from nil, which
      # means "couldn't tell" (timeout, connection refused, 401, 5xx, a
      # malformed body). Callers treat GONE as authoritative revocation —
      # drop the cached profile, sign out — and nil as a transient
      # failure to degrade-to-cache against.
      #
      # A plain 404 is deliberately NOT revocation: 404 says a resource
      # wasn't found without saying which one. A mistyped
      # internal_profile_path, a route missing mid-deploy, a stale origin
      # image (a documented Render failure mode), or an intermediary's
      # own 404 page all produce it — and treating any of those as
      # "account gone" would destroy the cached profile and sign real
      # users out cluster-wide on an infrastructure hiccup. Only the
      # typed 410 carries revocation semantics; everything else degrades.
      GONE = :account_gone
      GONE_ERROR = "account_gone"

      class << self
        # expected_user_id: the identity the shared cookie asserts. The
        # response's own user_id must match it exactly — a provider
        # routing/cache/serialization bug that returns some OTHER user's
        # profile must not be persisted and displayed under this user's
        # identity, so a mismatch degrades to nil like any other
        # malformed response.
        def fetch(shared_identity_cookie, expected_user_id:)
          return nil if shared_identity_cookie.blank?

          uri = URI("#{root_base_url}#{SubpathIdentity.config.internal_profile_path}")
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = 2
          http.read_timeout = 2

          # CGI.escape, not the raw value: Rack decodes incoming cookie
          # values with URI.decode_www_form_component, which turns a
          # literal "+" into a space. The encrypted cookie is base64 and
          # routinely contains "+", so an unescaped value here gets
          # silently corrupted in transit and the provider's decode
          # fails closed (401).
          request = Net::HTTP::Get.new(uri)
          request["Cookie"] = "#{SubpathIdentity.config.cookie_name}=#{CGI.escape(shared_identity_cookie)}"

          response = http.request(request)
          return GONE if account_gone?(response)
          return nil unless response.is_a?(Net::HTTPSuccess)

          profile = JSON.parse(response.body, symbolize_names: true)
          # A 2xx whose body parses cleanly but isn't a usable profile —
          # a bare true/number/string/array, or an object missing the
          # keys the caller dereferences — is an upstream or intermediary
          # bug, not a real profile. Degrade to nil (caller keeps its
          # cache) rather than hand back a truthy non-Hash that
          # SyncLocalProfile would then call remote[:cache_key] on and
          # 500. JSON::ParserError (a syntactically invalid body) is
          # already caught below; this covers the valid-JSON-wrong-shape
          # case that parses without raising.
          return nil unless profile.is_a?(Hash) && profile[:user_id].present? && profile[:cache_key].present?
          return nil unless profile[:user_id].to_s == expected_user_id.to_s

          profile
        rescue Net::OpenTimeout, Net::ReadTimeout, Net::ProtocolError, Net::HTTPBadResponse,
          SocketError, SystemCallError, EOFError, OpenSSL::SSL::SSLError, JSON::ParserError
          # SystemCallError is the parent of every Errno::* the
          # underlying socket can raise (ECONNRESET, ECONNREFUSED,
          # EHOSTUNREACH, ETIMEDOUT, ...) — named once here instead of
          # enumerating each one. Net::HTTPBadResponse is listed
          # separately from Net::ProtocolError on purpose — despite the
          # name, it isn't part of that hierarchy (see
          # net/http/response.rb — Net::HTTPResponse.read_new raises it
          # directly on a malformed status line), so Net::ProtocolError
          # alone doesn't catch it. Deliberately not rescue
          # StandardError: that would also swallow real programming
          # defects in this method, not just the network's.
          nil
        end

        private

        # Only a 410 whose JSON body carries the typed marker counts as
        # revocation (see the GONE constant's comment for why a plain
        # 404 must not). An intermediary that happens to emit a bare 410
        # with an HTML error page still doesn't qualify — the body has
        # to say account_gone.
        def account_gone?(response)
          return false unless response.is_a?(Net::HTTPGone)

          body = JSON.parse(response.body, symbolize_names: true)
          body.is_a?(Hash) && body[:error] == GONE_ERROR
        rescue JSON::ParserError
          false
        end

        def root_base_url
          origin = SubpathIdentity.config.root_origin
          scheme = origin.start_with?("localhost", "127.0.0.1") ? "http" : "https"
          "#{scheme}://#{origin}"
        end
      end
    end
  end
end
