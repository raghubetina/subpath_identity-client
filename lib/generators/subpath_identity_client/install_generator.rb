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

            Add the columns your app wants to cache (e.g. email, name) to
            BOTH the migration and the model before running db:migrate --
            the generated migration has only global_user_id and
            root_cache_key, so a sync block writing profile.email against
            a table without that column will fail. Then configure how the
            columns are populated. Note the to_prepare wrapper: this file
            loads before Zeitwerk is ready, so naming LocalProfile at the
            top level raises NameError -- to_prepare defers it to after
            boot.

              # config/initializers/subpath_identity.rb
              Rails.application.config.to_prepare do
                SubpathIdentity.configure do |config|
                  config.local_profile_model = LocalProfile
                  config.sync_remote_profile do |profile, remote|
                    profile.email = remote[:email]
                  end
                end
              end

          TEXT
        end
      end
    end
  end
end
