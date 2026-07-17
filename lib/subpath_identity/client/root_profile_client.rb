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
      class << self
        def fetch(shared_identity_cookie)
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
          return nil unless response.is_a?(Net::HTTPSuccess)

          JSON.parse(response.body, symbolize_names: true)
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

        def root_base_url
          origin = SubpathIdentity.config.root_origin
          scheme = origin.start_with?("localhost", "127.0.0.1") ? "http" : "https"
          "#{scheme}://#{origin}"
        end
      end
    end
  end
end
