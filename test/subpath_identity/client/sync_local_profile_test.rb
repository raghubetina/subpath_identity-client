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

    # Stands in for ControllerHelpers#write_shared_identity (unit-tested
    # in the core gem, including that it preserves the identity's
    # absolute deadline). Mimics the observable effect SyncLocalProfile
    # relies on: the current identity's claims change, and the browser
    # would carry the rewritten cookie on its next request.
    def write_shared_identity(**claims)
      (@written_identity_claims ||= []) << claims
      fake_shared_identity.merge!(claims)
    end

    def written_identity_claims
      @written_identity_claims || []
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

    SubpathIdentity::Client::RootProfileClient.stub(:fetch, ->(*, **) { raise "should not be called" }) do
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

  # Also through the REAL fetch: a well-formed profile for the WRONG
  # user (a provider routing/cache bug) must neither create nor update a
  # row under this user's identity, and must not be treated as
  # revocation either.
  def test_a_profile_for_another_user_is_never_persisted_under_this_users_id
    body = {user_id: 2, email: "user2@example.com", cache_key: "accounts/2-v1"}.to_json
    ok = Net::HTTPOK.new("1.1", "200", "OK")
    ok.instance_variable_set(:@read, true)
    ok.instance_variable_set(:@body, body)
    fake_http = Object.new
    fake_http.define_singleton_method(:use_ssl=) { |_| }
    fake_http.define_singleton_method(:open_timeout=) { |_| }
    fake_http.define_singleton_method(:read_timeout=) { |_| }
    fake_http.define_singleton_method(:request) { |_req| ok }

    Net::HTTP.stub(:new, fake_http) do
      controller = build_controller(user_id: 1, cache_key: "accounts/1-v1")
      controller.process(:index)

      assert_nil controller.current_local_profile
      assert_equal 0, LocalProfile.count, "no row may be written from another user's profile"
      refute controller.cleared_shared_identity
    end
  end

  # Regression for a non-converging refetch loop: on a first visit the
  # provider can legitimately return a NEWER cache_key than the browser
  # cookie carries (the account was edited from another device after the
  # cookie was issued). The fix: store the provider's authoritative key
  # in the row AND reissue this browser's cookie with it, so the next
  # request compares equal. The browser's evolved cookie state is
  # simulated between requests, exactly as a real browser would carry
  # the rewritten cookie forward.
  def test_a_provider_snapshot_newer_than_the_cookie_does_not_cause_a_refetch_loop
    body = {user_id: 1, email: "fresh@example.com", cache_key: "accounts/1-v2"}.to_json
    fetches = 0
    fake_http = Object.new
    fake_http.define_singleton_method(:use_ssl=) { |_| }
    fake_http.define_singleton_method(:open_timeout=) { |_| }
    fake_http.define_singleton_method(:read_timeout=) { |_| }
    fake_http.define_singleton_method(:request) do |_req|
      fetches += 1
      ok = Net::HTTPOK.new("1.1", "200", "OK")
      ok.instance_variable_set(:@read, true)
      ok.instance_variable_set(:@body, body)
      ok
    end

    browser_cache_key = "accounts/1-v1"
    Net::HTTP.stub(:new, fake_http) do
      2.times do
        controller = build_controller(user_id: 1, cache_key: browser_cache_key)
        controller.process(:index)

        assert_equal "fresh@example.com", controller.current_local_profile.email
        # Carry the rewritten cookie forward, as the browser would.
        browser_cache_key = controller.current_shared_identity[:cache_key]
      end
    end

    assert_equal 1, fetches, "the second request must be served from the converged cache"
    assert_equal "accounts/1-v2", browser_cache_key,
      "the browser's cookie should have been reissued with the provider's key"
    assert_equal "accounts/1-v2", LocalProfile.find_by(global_user_id: 1).root_cache_key,
      "the row records the provider's authoritative key"
  end

  # Regression for cache oscillation between two browsers: one holds a
  # still-valid v1 cookie, another holds v2, the provider is on v2. A
  # single shared row can't record both browsers' versions, so before
  # the cookie-reissue fix each alternating request overwrote the row to
  # its own claim and forced the other browser to refetch — a provider
  # call and a database write on EVERY request, forever. Now each stale
  # browser pays for exactly one fetch and everyone converges on the
  # provider's key.
  def test_two_browsers_with_different_cookie_versions_converge_instead_of_oscillating
    body = {user_id: 1, email: "fresh@example.com", cache_key: "accounts/1-v2"}.to_json
    fetches = 0
    fake_http = Object.new
    fake_http.define_singleton_method(:use_ssl=) { |_| }
    fake_http.define_singleton_method(:open_timeout=) { |_| }
    fake_http.define_singleton_method(:read_timeout=) { |_| }
    fake_http.define_singleton_method(:request) do |_req|
      fetches += 1
      ok = Net::HTTPOK.new("1.1", "200", "OK")
      ok.instance_variable_set(:@read, true)
      ok.instance_variable_set(:@body, body)
      ok
    end

    browsers = {a: "accounts/1-v1", b: "accounts/1-v2"}
    Net::HTTP.stub(:new, fake_http) do
      # Alternate a, b, a, b — the review-8 oscillation sequence.
      %i[a b a b].each do |browser|
        controller = build_controller(user_id: 1, cache_key: browsers[browser])
        controller.process(:index)
        browsers[browser] = controller.current_shared_identity[:cache_key]
      end
    end

    assert_equal 1, fetches,
      "only browser a's one stale request may contact the provider; alternation must not oscillate"
    assert_equal "accounts/1-v2", browsers[:a]
    assert_equal "accounts/1-v2", browsers[:b]
    assert_equal "accounts/1-v2", LocalProfile.find_by(global_user_id: 1).root_cache_key
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
