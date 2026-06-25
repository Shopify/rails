# frozen_string_literal: true

module ActiveRecord
  module Associations
    class Preloader
      class Batch # :nodoc:
        def initialize(preloaders, available_records:)
          @preloaders = preloaders.reject(&:empty?)
          @available_records = available_records.flatten.group_by { |r| r.class.base_class }
        end

        def call
          branch_groups = @preloaders.flat_map(&:branch_groups)

          until branch_groups.empty?
            target_loaders = branch_groups.map { |branches| runnable_loaders_for(branches) }

            load_records(target_loaders.flat_map { |loaders| loader_records(loaders) }).each(&:value)
            target_loaders.flatten.each(&:run)

            branch_groups = branch_groups.filter_map do |branches|
              finished, in_progress = branches.partition(&:done?)
              branches = in_progress + finished.flat_map(&:children)
              branches if branches.any?
            end
          end
        end

        private
          def runnable_loaders_for(branches)
            loaders = branches.flat_map(&:runnable_loaders)

            loaders.each { |loader| loader.associate_records_from_unscoped(@available_records[loader.klass.base_class]) }

            return [] if loaders.empty?

            future_tables = branches.flat_map do |branch|
              branch.future_classes - branch.runnable_loaders.map(&:klass)
            end.map(&:table_name).uniq

            target_loaders = loaders.reject { |l| future_tables.include?(l.table_name)  }
            target_loaders.presence || loaders
          end

          def load_records(record_loads)
            promises_by_key = {}

            record_loads.map do |record_load|
              dependencies = record_load.read_keys.filter_map { |key| promises_by_key[key] }
              promise = if dependency = dependencies.find(&:pending?)
                dependency.then do
                  record_load.load(pipeline: true).value
                end
              else
                record_load.load(pipeline: true)
              end

              record_load.write_keys.each { |key| promises_by_key[key] = promise }
              promise
            end
          end

          def loader_records(loaders)
            loaders.grep_v(ThroughAssociation).group_by do |loader|
              [loader.loader_query, loader.klass]
            end.map do |(query, _klass), similar_loaders|
              query.loader_records(similar_loaders)
            end
          end
      end
    end
  end
end
