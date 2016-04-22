require "active_record/associations"

module ActiveRecord::Turntable
  module ActiveRecordExt
    module Association
      extend ActiveSupport::Concern

      included do
        ActiveRecord::Associations::SingularAssociation.include(SingularAssociationExt)
        ActiveRecord::Associations::CollectionAssociation.include(CollectionAssociationExt)
        ActiveRecord::Associations::Builder::Association.valid_options += [:foreign_shard_key]
      end

      private

        def turntable_scope(scope, bind = nil)
          if should_use_shard_key?
            scope = scope.where(klass.turntable_shard_key => owner.send(foreign_shard_key))
          end
          scope
        end

        module SingularAssociationExt
          extend ActiveSupport::Concern

          included do
            alias_method_chain :get_records, :turntable
          end

          # @note Override to add sharding condition for singular association
          def get_records_with_turntable
            if reflection.scope_chain.any?(&:any?) ||
                scope.eager_loading? ||
                klass.current_scope ||
                klass.default_scopes.any? ||
                should_use_shard_key? # OPTIMIZE: Use bind values if cachable scope

              return turntable_scope(scope).limit(1).to_a
            end

            conn = klass.connection
            sc = reflection.association_scope_cache(conn, owner) do
              ActiveRecord::StatementCache.create(conn) { |params|
                as = ActiveRecord::Associations::AssociationScope.create { params.bind }
                target_scope.merge(as.scope(self, conn)).limit(1)
              }
            end

            binds = ActiveRecord::Associations::AssociationScope.get_bind_values(owner, reflection.chain)
            sc.execute binds, klass, klass.connection
          end
        end

        module CollectionAssociationExt
          extend ActiveSupport::Concern

          included do
            alias_method_chain :get_records, :turntable
          end

          private

          def get_records_with_turntable
            if reflection.scope_chain.any?(&:any?) ||
                scope.eager_loading? ||
                klass.current_scope ||
                klass.default_scopes.any? ||
                should_use_shard_key? # OPTIMIZE: Use bind values if cachable scope

              return turntable_scope(scope).to_a
            end

            conn = klass.connection
            sc = reflection.association_scope_cache(conn, owner) do
              ActiveRecord::StatementCache.create(conn) { |params|
                as = ActiveRecord::Associations::AssociationScope.create { params.bind }
                target_scope.merge as.scope(self, conn)
              }
            end

            binds = ActiveRecord::Associations::AssociationScope.get_bind_values(owner, reflection.chain)
            sc.execute binds, klass, klass.connection
          end
        end

        private

        def foreign_shard_key
          options[:foreign_shard_key] || owner.turntable_shard_key
        end

        def should_use_shard_key?
          same_association_shard_key? || !!options[:foreign_shard_key]
        end

        def same_association_shard_key?
          owner.class.turntable_enabled? && klass.turntable_enabled? && foreign_shard_key == klass.turntable_shard_key
        end
    end
  end
end
