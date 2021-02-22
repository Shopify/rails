# frozen_string_literal: true

module ActiveRecord
  module Associations
    class Preloader
      class Batch #:nodoc:
        def initialize(preloaders)
          @preloaders = preloaders.reject(&:empty?)
        end

        def call
          branches = @preloaders.flat_map(&:branches)
          until branches.empty?
            loaders = branches.flat_map(&:runnable_loaders)

            already_loaded = loaders.select { |l| !l.run? && l.already_loaded? }
            if already_loaded.any?
              already_loaded.each(&:run)
            else
              group_and_load_similar(loaders)
              loaders.each(&:run)
            end

            finished, in_progress = branches.partition(&:done?)

            branches = in_progress + finished.flat_map(&:children)
          end
        end

        private
          attr_reader :loaders

          def group_and_load_similar(loaders)
            loaders.grep_v(ThroughAssociation).group_by(&:grouping_key).each do |(_, _, association_key_name), similar_loaders|
              next if similar_loaders.all? { |l| l.already_loaded? }

              scope = similar_loaders.first.scope
              Association.load_records_in_batch(scope, association_key_name, similar_loaders)
            end
          end
      end
    end
  end
end
