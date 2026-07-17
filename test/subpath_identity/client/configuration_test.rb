# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < Minitest::Test
  def teardown
    SubpathIdentity.reset_config!
    ENV.delete("CUSTOM_ROOT_ORIGIN")
  end

  def test_defaults
    config = SubpathIdentity::Configuration.new

    assert_equal "ROOT_ORIGIN", config.root_origin_env_var
    assert_equal "/internal/me", config.internal_profile_path
    assert_equal "localhost:3000", config.root_origin
  end

  def test_root_origin_reads_from_the_configured_env_var_name
    SubpathIdentity.configure { |c| c.root_origin_env_var = "CUSTOM_ROOT_ORIGIN" }
    ENV["CUSTOM_ROOT_ORIGIN"] = "root.example.com"

    assert_equal "root.example.com", SubpathIdentity.config.root_origin
  end

  def test_local_profile_model_raises_until_configured
    error = assert_raises(RuntimeError) { SubpathIdentity.config.local_profile_model }
    assert_match(/local_profile_model is not set/, error.message)
  end

  def test_local_profile_model_returns_the_configured_model
    fake_model = Class.new
    SubpathIdentity.configure { |c| c.local_profile_model = fake_model }

    assert_equal fake_model, SubpathIdentity.config.local_profile_model
  end

  def test_sync_remote_profile_stores_and_returns_the_block
    SubpathIdentity.configure do |c|
      c.sync_remote_profile { |profile, remote| profile.email = remote[:email] }
    end

    block = SubpathIdentity.config.sync_remote_profile
    refute_nil block

    fake_profile = Struct.new(:email).new
    block.call(fake_profile, {email: "a@example.com"})
    assert_equal "a@example.com", fake_profile.email
  end

  def test_sync_remote_profile_returns_nil_when_never_configured
    assert_nil SubpathIdentity.config.sync_remote_profile
  end
end
