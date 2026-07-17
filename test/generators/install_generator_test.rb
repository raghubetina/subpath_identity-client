# frozen_string_literal: true

require "test_helper"
require "generators/subpath_identity_client/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests SubpathIdentity::Client::Generators::InstallGenerator
  destination File.expand_path("../../tmp", __dir__)
  setup :prepare_destination

  def test_migration
    run_generator

    assert_migration "db/migrate/create_local_profiles.rb", /class CreateLocalProfiles < ActiveRecord::Migration/
    assert_migration "db/migrate/create_local_profiles.rb", /create_table :local_profiles do/
    assert_migration "db/migrate/create_local_profiles.rb", /t\.integer :global_user_id, null: false/
    assert_migration "db/migrate/create_local_profiles.rb", /add_index :local_profiles, :global_user_id, unique: true/
  end

  def test_model
    run_generator

    assert_file "app/models/local_profile.rb", /class LocalProfile < ApplicationRecord/
    assert_file "app/models/local_profile.rb", /validates :global_user_id, presence: true/
    refute_file_matches "app/models/local_profile.rb", /validates :global_user_id, uniqueness/
  end

  def test_show_readme_output
    output = run_generator

    assert_match "config/initializers/subpath_identity.rb", output
    assert_match "local_profile_model = LocalProfile", output
  end

  private

  def refute_file_matches(relative, regexp)
    assert_no_match regexp, File.read(File.join(destination_root, relative))
  end
end
