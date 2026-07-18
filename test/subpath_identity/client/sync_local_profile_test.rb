# frozen_string_literal: true

require "test_helper"

class SyncLocalProfileTest < Minitest::Test
  class FakeController < ActionController::Base
    include SubpathIdentity::Client::SyncLocalProfile

    attr_accessor :fake_signed_in, :fake_shared_identity, :fake_cookies
    attr_reader :cleared_shared_identity

    def signed_in?
      fake_signed_in
    end

    def current_shared_identity
      fake_shared_identity
    end

    def cookies
      fake_cookies
    end

    # Stands in for SubpathIdentity::ControllerHelpers#clear_shared_identity,
    # which the real host controller provides (SyncLocalProfile expects it
    # to be included first). The real one is unit-tested in the core gem;
    # here we only need to verify SyncLocalProfile *calls* it on GONE.
    def clear_shared_identity
      @cleared_shared_identity = true
      fake_cookies.delete(SubpathIdentity.config.cookie_name)
      self.fake_signed_in = false
    end

    def index
      head :ok
    end
  end

  def setup
    LocalProfile.delete_all
    SubpathIdentity.configure do |c|
      c.local_profile_model = LocalProfile
      c.sync_remote_profile { |profile, remote| profile.email = remote[:email] }
    end
  end

  def teardown
    SubpathIdentity.reset_config!
  end

  def build_controller(user_id:, cache_key:)
    controller = FakeController.new
    controller.fake_signed_in = true
    controller.fake_shared_identity = {user_id: user_id, cache_key: cache_key}
    controller.fake_cookies = {_shared_identity: "cookie-for-#{user_id}"}
    controller.request = ActionDispatch::TestRequest.create
    controller.response = ActionDispatch::TestResponse.new
    controller
  end

  def test_is_a_no_op_when_signed_out
    controller = FakeController.new
    controller.fake_signed_in = false
    controller.request = ActionDispatch::TestRequest.create
    controller.response = ActionDispatch::TestResponse.new

    controller.process(:index)

    assert_nil controller.current_local_profile
    assert_equal 0, LocalProfile.count
  end

  def test_creates_a_local_profile_on_first_visit
    remote = {user_id: 1, email: "a@example.com", cache_key: "accounts/1-v1"}
    SubpathIdentity::Client::RootProfileClient.stub(:fetch, remote) do
      controller = build_controller(user_id: 1, cache_key: "accounts/1-v1")
      controller.process(:index)

      assert_equal "a@example.com", controller.current_local_profile.email
      assert_equal "accounts/1-v1", controller.current_local_profile.root_cache_key
    end
  end

  def test_does_not_refetch_when_the_cache_key_matches
    LocalProfile.create!(global_user_id: 1, root_cache_key: "accounts/1-v1", email: "cached@example.com")

    SubpathIdentity::Client::RootProfileClient.stub(:fetch, ->(*) { raise "should not be called" }) do
      controller = build_controller(user_id: 1, cache_key: "accounts/1-v1")
      controller.process(:index)

      assert_equal "cached@example.com", controller.current_local_profile.email
    end
  end

  def test_refetches_when_the_cache_key_has_moved
    LocalProfile.create!(global_user_id: 1, root_cache_key: "accounts/1-v1", email: "stale@example.com")
    remote = {user_id: 1, email: "fresh@example.com", cache_key: "accounts/1-v2"}

    SubpathIdentity::Client::RootProfileClient.stub(:fetch, remote) do
      controller = build_controller(user_id: 1, cache_key: "accounts/1-v2")
      controller.process(:index)

      assert_equal "fresh@example.com", controller.current_local_profile.email
      assert_equal "accounts/1-v2", controller.current_local_profile.root_cache_key
    end
  end

  def test_keeps_the_stale_cached_profile_when_the_provider_is_unreachable
    LocalProfile.create!(global_user_id: 1, root_cache_key: "accounts/1-v1", email: "cached@example.com")

    SubpathIdentity::Client::RootProfileClient.stub(:fetch, nil) do
      controller = build_controller(user_id: 1, cache_key: "accounts/1-v2")
      controller.process(:index)

      refute_nil controller.current_local_profile
      assert_equal "cached@example.com", controller.current_local_profile.email
      refute controller.cleared_shared_identity, "a transient nil must not revoke the identity"
    end
  end

  def test_revokes_the_local_identity_when_the_provider_reports_the_account_gone
    LocalProfile.create!(global_user_id: 1, root_cache_key: "accounts/1-v1", email: "closed@example.com")

    gone = SubpathIdentity::Client::RootProfileClient::GONE
    SubpathIdentity::Client::RootProfileClient.stub(:fetch, gone) do
      # cache_key mismatch forces the fetch that surfaces the GONE result.
      controller = build_controller(user_id: 1, cache_key: "accounts/1-v2")
      controller.process(:index)

      assert_nil controller.current_local_profile
      assert_nil LocalProfile.find_by(global_user_id: 1), "the stale local row should be destroyed"
      assert controller.cleared_shared_identity, "the shared identity cookie should be cleared"
      assert_nil controller.fake_cookies[:_shared_identity]
    end
  end

  # Exercises the REAL RootProfileClient.fetch (only the HTTP layer is
  # stubbed), not a stubbed fetch — this is the exact path that used to
  # 500: a 2xx body of bare `true` came back truthy-but-not-a-Hash and
  # sync_local_profile called remote[:cache_key] on it. fetch now
  # degrades a malformed body to nil, so the before_action survives.
  def test_a_malformed_provider_body_degrades_instead_of_crashing_the_before_action
    ok = Net::HTTPOK.new("1.1", "200", "OK")
    ok.instance_variable_set(:@read, true)
    ok.instance_variable_set(:@body, "true")
    fake_http = Object.new
    fake_http.define_singleton_method(:use_ssl=) { |_| }
    fake_http.define_singleton_method(:open_timeout=) { |_| }
    fake_http.define_singleton_method(:read_timeout=) { |_| }
    fake_http.define_singleton_method(:request) { |_req| ok }

    Net::HTTP.stub(:new, fake_http) do
      # First visit (no local row) forces the fetch.
      controller = build_controller(user_id: 1, cache_key: "accounts/1-v1")
      controller.process(:index)

      assert_nil controller.current_local_profile
      assert_nil LocalProfile.find_by(global_user_id: 1)
      refute controller.cleared_shared_identity, "a malformed 2xx is a degrade, not a revocation"
    end
  end

  # Regression test for a real race: two concurrent first-visits from the
  # same user can both see no local row and both attempt to insert one.
  # create_or_find_by is relied on to rescue that instead of raising —
  # which only works because LocalProfile (see test_helper.rb) has no
  # uniqueness validation on global_user_id. A barrier forces both
  # threads past the "no row exists" read before either writes,
  # reproducing the exact race window a plain sequential test would miss.
  def test_create_or_find_by_survives_two_concurrent_first_visits_for_the_same_user
    global_user_id = 999_001
    remote = {user_id: global_user_id, email: "racer@example.com", cache_key: "accounts/1-v1"}

    ready = Queue.new
    go = Queue.new
    results = []
    mutex = Mutex.new

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << LocalProfile.find_by(global_user_id: global_user_id).nil?
          go.pop
          controller = build_controller(user_id: global_user_id, cache_key: "accounts/1-v1")
          SubpathIdentity::Client::RootProfileClient.stub(:fetch, remote) do
            controller.process(:index)
          end
          mutex.synchronize { results << controller.current_local_profile.id }
        end
      end
    end

    both_saw_no_row = 2.times.map { ready.pop }
    2.times { go << true }
    threads.each(&:join)

    assert_equal [true, true], both_saw_no_row, "test setup didn't actually force the race"
    assert_equal 1, results.uniq.size, "both threads should converge on the same row"
    assert_equal 1, LocalProfile.where(global_user_id: global_user_id).count
  end
end
