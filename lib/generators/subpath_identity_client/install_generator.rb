# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record/migration"

module SubpathIdentity
  module Client
    module Generators
      class InstallGenerator < ::Rails::Generators::Base
        include ::ActiveRecord::Generators::Migration

        source_root "#{__dir__}/templates"
        namespace "subpath_identity_client:install"

        def create_migration_file
          migration_template "create_local_profiles.rb.erb", "db/migrate/create_local_profiles.rb"
        end

        def create_model_file
          template "local_profile.rb", "app/models/local_profile.rb"
        end

        def show_readme
          say <<~TEXT

            Generated:
              db/migrate/*_create_local_profiles.rb
              app/models/local_profile.rb

            Add your own columns to the migration and model before running
            db:migrate, then configure how they're populated:

              # config/initializers/subpath_identity.rb
              SubpathIdentity.configure do |config|
                config.local_profile_model = LocalProfile
                config.sync_remote_profile do |profile, remote|
                  profile.email = remote[:email]
                end
              end

          TEXT
        end
      end
    end
  end
end
