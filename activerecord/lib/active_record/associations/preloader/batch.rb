# frozen_string_literal: true

module ActiveRecord
  module Associations
    class Preloader
      class Batch # :nodoc:
        def initialize(preloaders, available_records:)
          @preloaders = preloaders.reject(&:empty?)
          @available_records = available_records.flatten.group_by { |r| r.class.base_class }
          @preload_writes = {}.compare_by_identity
        end

        def call
          branch_groups = @preloaders.flat_map(&:branch_groups).map.with_index do |branches, index|
            [branches, index]
          end
          dependencies = top_level_dependencies(branch_groups.map(&:first))

          until branch_groups.empty?
            unfinished = branch_groups.map(&:last)
            active, waiting = branch_groups.partition do |_branches, index|
              (dependencies[index] & unfinished).empty?
            end

            pending = []
            target_loaders = []
            active.each do |branches, _index|
              realize(pending) if pending.any? && instance_dependent_scope?(branches)
              loaders = runnable_loaders_for(branches)
              target_loaders.concat(loaders)
              plan_records(loader_records(loaders), pending)
            end
            realize(pending)
            target_loaders.each(&:run)

            branch_groups = (waiting + active.filter_map do |branches, index|
              finished, in_progress = branches.partition(&:done?)
              branches = in_progress + finished.flat_map(&:children)
              [branches, index] if branches.any?
            end).sort_by(&:last)
          end
        end

        private
          def top_level_dependencies(branch_groups)
            dependencies = Array.new(branch_groups.length) { [] }
            through_dependencies = branch_groups.map { |branches| branches.flat_map { |branch| through_dependencies_for(branch) } }

            branch_groups.each_with_index do |branches, index|
              associations = branches.map(&:association)
              through_dependencies.each_with_index do |dependencies_for_group, dependency_index|
                next unless dependency_index < index

                dependencies[index] << dependency_index if (dependencies_for_group & associations).any?
              end
            end

            dependencies
          end

          def through_dependencies_for(branch)
            branch.source_records.filter_map do |record|
              reflection = record.class._reflect_on_association(branch.association)
              reflection.through_reflection.name if reflection&.options&.[](:through)
            end.uniq
          end

          def runnable_loaders_for(branches)
            loaders = branches.flat_map do |branch|
              branch.runnable_loaders.each do |loader|
                loader.preload_context = [branch.preload_index, @preload_writes]
              end
            end

            loaders.each { |loader| loader.associate_records_from_unscoped(@available_records[loader.klass.base_class]) }

            return [] if loaders.empty?

            future_tables = branches.flat_map do |branch|
              branch.future_classes - branch.runnable_loaders.map(&:klass)
            end.map(&:table_name).uniq

            target_loaders = loaders.reject { |l| future_tables.include?(l.table_name)  }
            target_loaders.presence || loaders
          end

          def instance_dependent_scope?(branches)
            branches.any? do |branch|
              branch.source_records.any? do |record|
                reflection = record.class._reflect_on_association(branch.association)
                reflection&.scope && reflection.scope.arity != 0
              end
            end
          end

          def plan_records(record_loads, pending)
            record_loads.each do |record_load|
              record_load.plan(pending_record_loads: pending).enqueue(pipeline: true)
              if record_load.deferred?
                pending << record_load
              else
                record_load.realize
              end
            end
          end

          def realize(record_loads)
            record_loads.each(&:realize)
            record_loads.clear
          end

          def loader_records(loaders)
            loaders.grep_v(ThroughAssociation).group_by do |loader|
              [loader.loader_query, loader.klass]
            end.map do |(query, _klass), similar_loaders|
              query.loader_records(similar_loaders, preload_writes: @preload_writes)
            end
          end
      end
    end
  end
end
