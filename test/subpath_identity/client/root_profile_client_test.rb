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
      assert_nil SubpathIdentity::Client::RootProfileClient.fetch(nil)
      assert_nil SubpathIdentity::Client::RootProfileClient.fetch("")
    end
  end

  def test_returns_the_parsed_profile_on_a_successful_response
    body = {user_id: 1, email: "a@example.com", cache_key: "accounts/1-v1"}.to_json
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, body)

    Net::HTTP.stub(:new, FakeNetHTTP.new(response)) do
      result = SubpathIdentity::Client::RootProfileClient.fetch("some-cookie")
      assert_equal 1, result[:user_id]
      assert_equal "a@example.com", result[:email]
    end
  end

  def test_returns_nil_on_a_non_success_http_response
    response = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")

    Net::HTTP.stub(:new, FakeNetHTTP.new(response)) do
      assert_nil SubpathIdentity::Client::RootProfileClient.fetch("some-cookie")
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
        assert_nil SubpathIdentity::Client::RootProfileClient.fetch("some-cookie")
      end
    end
  end

  def test_returns_nil_on_a_malformed_json_body
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, "not json")

    Net::HTTP.stub(:new, FakeNetHTTP.new(response)) do
      assert_nil SubpathIdentity::Client::RootProfileClient.fetch("some-cookie")
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
      SubpathIdentity::Client::RootProfileClient.fetch("abc+def/ghi=")
    end

    assert_equal "_shared_identity=abc%2Bdef%2Fghi%3D", seen_header
  end
end
