# frozen_string_literal: true

require "test_helper"

# A minimal double standing in for Net::HTTP itself. RootProfileClient
# calls Net::HTTP.new then sets use_ssl=/open_timeout=/read_timeout=
# before calling #request — stubbing Net::HTTP.new to return one of
# these lets a test control exactly what #request does, without pulling
# in a "stub any instance" gem for something this narrow (Minitest 6
# dropped mock.rb into its own gem).
class FakeNetHTTP
  attr_accessor :use_ssl, :open_timeout, :read_timeout

  def initialize(result)
    @result = result
  end

  def request(*)
    raise @result if @result.is_a?(Exception)

    @result
  end
end

class RootProfileClientTest < Minitest::Test
  def setup
    SubpathIdentity.configure { |c| c.root_origin_env_var = "TEST_ROOT_ORIGIN" }
    ENV["TEST_ROOT_ORIGIN"] = "localhost:3000"
  end

  def teardown
    SubpathIdentity.reset_config!
    ENV.delete("TEST_ROOT_ORIGIN")
  end

  def test_returns_nil_without_making_a_request_when_the_cookie_is_blank
    Net::HTTP.stub(:new, ->(*) { raise "should not be called" }) do
      assert_nil SubpathIdentity::Client::RootProfileClient.fetch(nil, expected_user_id: 1)
      assert_nil SubpathIdentity::Client::RootProfileClient.fetch("", expected_user_id: 1)
    end
  end

  def test_returns_the_parsed_profile_on_a_successful_response
    body = {user_id: 1, email: "a@example.com", cache_key: "accounts/1-v1"}.to_json
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, body)

    Net::HTTP.stub(:new, FakeNetHTTP.new(response)) do
      result = SubpathIdentity::Client::RootProfileClient.fetch("some-cookie", expected_user_id: 1)
      assert_equal 1, result[:user_id]
      assert_equal "a@example.com", result[:email]
    end
  end

  def test_returns_nil_on_a_401_which_is_a_secret_mismatch_not_a_missing_account
    # 401 means the provider couldn't authenticate the cookie the client
    # thinks is valid (secret skew, clock skew) — transient/config, not
    # "this account is gone." Must stay nil (degrade to cache), not GONE.
    response = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")

    Net::HTTP.stub(:new, FakeNetHTTP.new(response)) do
      assert_nil SubpathIdentity::Client::RootProfileClient.fetch("some-cookie", expected_user_id: 1)
    end
  end

  def test_returns_nil_on_a_5xx_server_error
    response = Net::HTTPInternalServerError.new("1.1", "500", "Internal Server Error")

    Net::HTTP.stub(:new, FakeNetHTTP.new(response)) do
      assert_nil SubpathIdentity::Client::RootProfileClient.fetch("some-cookie", expected_user_id: 1)
    end
  end

  def test_returns_nil_for_an_untyped_404_which_could_be_deploy_skew_not_revocation
    # A 404 doesn't say WHAT was missing: a wrong internal_profile_path,
    # a route absent mid-deploy, a stale origin image, an intermediary's
    # own 404 page. None of those mean "this account is gone," and
    # treating them as revocation would sign real users out cluster-wide
    # on an infrastructure hiccup. Must degrade to nil, never GONE.
    response = Net::HTTPNotFound.new("1.1", "404", "Not Found")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, "<html><body>404 route missing</body></html>")

    Net::HTTP.stub(:new, FakeNetHTTP.new(response)) do
      assert_nil SubpathIdentity::Client::RootProfileClient.fetch("some-cookie", expected_user_id: 1)
    end
  end

  def test_returns_gone_for_a_410_with_the_typed_account_gone_body
    response = Net::HTTPGone.new("1.1", "410", "Gone")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, {error: "account_gone"}.to_json)

    Net::HTTP.stub(:new, FakeNetHTTP.new(response)) do
      assert_equal SubpathIdentity::Client::RootProfileClient::GONE,
        SubpathIdentity::Client::RootProfileClient.fetch("some-cookie", expected_user_id: 1)
    end
  end

  def test_returns_nil_for_a_410_without_the_typed_body
    # A bare 410 from an intermediary (an HTML error page, an empty
    # body) doesn't carry the provider's revocation semantics either —
    # only the typed JSON marker does.
    [%(<html>410</html>), "", {error: "something_else"}.to_json].each do |body|
      response = Net::HTTPGone.new("1.1", "410", "Gone")
      response.instance_variable_set(:@read, true)
      response.instance_variable_set(:@body, body)

      Net::HTTP.stub(:new, FakeNetHTTP.new(response)) do
        assert_nil SubpathIdentity::Client::RootProfileClient.fetch("some-cookie", expected_user_id: 1),
          "expected nil for 410 body #{body.inspect}"
      end
    end
  end

  def test_returns_nil_when_the_response_is_a_profile_for_a_different_user
    # A provider routing/cache/serialization bug that returns some OTHER
    # user's profile must not be persisted under this user's identity —
    # a well-formed response for the wrong user degrades like any other
    # malformed one.
    body = {user_id: 2, email: "user2@example.com", cache_key: "accounts/2-v1"}.to_json
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, body)

    Net::HTTP.stub(:new, FakeNetHTTP.new(response)) do
      assert_nil SubpathIdentity::Client::RootProfileClient.fetch("some-cookie", expected_user_id: 1)
    end
  end

  # A 2xx whose body parses as valid JSON but isn't a usable profile —
  # a bare scalar/array, or an object missing user_id/cache_key. These
  # parse without raising (so JSON::ParserError doesn't catch them) and
  # must degrade to nil, not be returned as a truthy non-Hash that the
  # caller then dereferences and 500s on.
  {
    "true" => "true",
    "a_number" => "42",
    "a_string" => %("just a string"),
    "an_array" => "[1,2,3]",
    "an_empty_object" => "{}",
    "an_object_missing_cache_key" => {user_id: 1, email: "a@example.com"}.to_json,
    "an_object_missing_user_id" => {cache_key: "accounts/1-v1"}.to_json
  }.each do |name, body|
    define_method("test_returns_nil_for_a_2xx_body_that_is_#{name}") do
      response = Net::HTTPOK.new("1.1", "200", "OK")
      response.instance_variable_set(:@read, true)
      response.instance_variable_set(:@body, body)

      Net::HTTP.stub(:new, FakeNetHTTP.new(response)) do
        assert_nil SubpathIdentity::Client::RootProfileClient.fetch("some-cookie", expected_user_id: 1)
      end
    end
  end

  [
    Net::OpenTimeout.new("timed out"),
    Net::ReadTimeout.new("timed out"),
    SocketError.new("getaddrinfo failed"),
    Errno::ECONNREFUSED.new,
    Errno::ECONNRESET.new,
    EOFError.new,
    OpenSSL::SSL::SSLError.new("certificate verify failed"),
    Net::HTTPBadResponse.new("not a valid HTTP response")
  ].each do |error|
    define_method("test_returns_nil_instead_of_raising_on_#{error.class}") do
      Net::HTTP.stub(:new, FakeNetHTTP.new(error)) do
        assert_nil SubpathIdentity::Client::RootProfileClient.fetch("some-cookie", expected_user_id: 1)
      end
    end
  end

  def test_returns_nil_on_a_malformed_json_body
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, "not json")

    Net::HTTP.stub(:new, FakeNetHTTP.new(response)) do
      assert_nil SubpathIdentity::Client::RootProfileClient.fetch("some-cookie", expected_user_id: 1)
    end
  end

  def test_forwards_the_cookie_value_percent_encoded
    seen_header = nil
    fake = Object.new
    fake.define_singleton_method(:use_ssl=) { |_| }
    fake.define_singleton_method(:open_timeout=) { |_| }
    fake.define_singleton_method(:read_timeout=) { |_| }
    fake.define_singleton_method(:request) do |req|
      seen_header = req["Cookie"]
      response = Net::HTTPOK.new("1.1", "200", "OK")
      response.instance_variable_set(:@read, true)
      response.instance_variable_set(:@body, "{}")
      response
    end

    Net::HTTP.stub(:new, fake) do
      SubpathIdentity::Client::RootProfileClient.fetch("abc+def/ghi=", expected_user_id: 1)
    end

    assert_equal "_shared_identity=abc%2Bdef%2Fghi%3D", seen_header
  end
end
