#
# force TestFixtures to begin transaction with all shards.
#
require "active_record/fixtures"

module ActiveRecord
  class FixtureSet
    extend ActiveRecord::Turntable::Util

    # rubocop:disable Style/MultilineMethodCallBraceLayout
    def self.create_fixtures(fixtures_directory, fixture_set_names, class_names = {}, config = ActiveRecord::Base)
      fixture_set_names = Array(fixture_set_names).map(&:to_s)
      class_names = ClassCache.new class_names, config

      # FIXME: Apparently JK uses this.
      connection = block_given? ? yield : ActiveRecord::Base.connection

      files_to_read = fixture_set_names.reject { |fs_name|
        fixture_is_cached?(connection, fs_name)
      }

      unless files_to_read.empty?
        connection.disable_referential_integrity do
          fixtures_map = {}

          fixture_sets = files_to_read.map do |fs_name|
            klass = class_names[fs_name]
            conn = klass ? klass.connection : connection
            fixtures_map[fs_name] = new( # ActiveRecord::FixtureSet.new
              conn,
              fs_name,
              klass,
              ::File.join(fixtures_directory, fs_name))
          end

          update_all_loaded_fixtures fixtures_map

          ActiveRecord::Base.force_transaction_all_shards!(requires_new: true) do
            deleted_tables = Hash.new { |h, k| h[k] = Set.new }
            fixture_sets.each do |fs|
              conn = fs.model_class.respond_to?(:connection) ? fs.model_class.connection : connection
              table_rows = fs.table_rows

              table_rows.each_key do |table|
                unless deleted_tables[conn].include? table
                  conn.delete "DELETE FROM #{conn.quote_table_name(table)}", "Fixture Delete"
                end
                deleted_tables[conn] << table
              end

              table_rows.each do |fixture_set_name, rows|
                rows.each do |row|
                  conn.insert_fixture(row, fixture_set_name)
                end
              end

              # Cap primary key sequences to max(pk).
              if connection.respond_to?(:reset_pk_sequence!)
                connection.reset_pk_sequence!(fs.table_name)
              end
            end
          end

          cache_fixtures(connection, fixtures_map)
        end
      end
      cached_fixtures(connection, fixture_set_names)
    end
    # rubocop:enable Style/MultilineMethodCallLayout
  end

  module TestFixtures
    # rubocop:disable Style/ClassVars, Style/RedundantException
    def setup_fixtures(config = ActiveRecord::Base)
      if pre_loaded_fixtures && !use_transactional_fixtures
        raise RuntimeError, "pre_loaded_fixtures requires use_transactional_fixtures"
      end

      @fixture_cache = {}
      @fixture_connections = []
      @@already_loaded_fixtures ||= {}

      # Load fixtures once and begin transaction.
      if run_in_transaction?
        if @@already_loaded_fixtures[self.class]
          @loaded_fixtures = @@already_loaded_fixtures[self.class]
        else
          @loaded_fixtures = load_fixtures(config)
          @@already_loaded_fixtures[self.class] = @loaded_fixtures
        end
        ActiveRecord::Base.force_connect_all_shards!
        @fixture_connections = enlist_fixture_connections
        @fixture_connections.each do |connection|
          connection.begin_transaction joinable: false
        end
      # Load fixtures for every test.
      else
        ActiveRecord::FixtureSet.reset_cache
        @@already_loaded_fixtures[self.class] = nil
        @loaded_fixtures = load_fixtures(config)
      end

      # Instantiate fixtures for every test if requested.
      instantiate_fixtures if use_instantiated_fixtures
    end
    # rubocop:enable Style/ClassVars, Style/RedundantException

    def enlist_fixture_connections
      ActiveRecord::Base.connection_handler.connection_pool_list.map(&:connection) +
        ActiveRecord::Base.turntable_connections.values.map(&:connection)
    end
  end
end
