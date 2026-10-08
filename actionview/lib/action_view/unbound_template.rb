# frozen_string_literal: true

require "concurrent/map"
require "monitor"
require "active_support/ractors"

module ActionView
  class UnboundTemplate
    # Only accessed on the main Ractor. Compilation hooks may enter other
    # caches, so they must not run under a shared-map lock.
    COMPILE_LOCK = Monitor.new
    private_constant :COMPILE_LOCK

    attr_reader :virtual_path, :details
    delegate :locale, :format, :variant, :handler, to: :@details

    def initialize(source, identifier, details:, virtual_path:)
      @source = source
      @identifier = identifier
      @details = details
      @virtual_path = virtual_path

      @strict_locals_template = nil
      @templates = Concurrent::Map.new(initial_capacity: 2)
      @write_lock = Mutex.new
    end

    def bind_locals(locals)
      if @strict_locals_template
        @strict_locals_template
      elsif frozen?
        @templates[locals] || bind_shared_template(locals)
      else
        @templates[locals] || build_bound_template(locals)
      end
    end

    def built_templates # :nodoc:
      if @strict_locals_template
        [@strict_locals_template]
      elsif frozen?
        @templates.to_h.values
      else
        @templates.values
      end
    end

    def freeze # :nodoc:
      return self if frozen?

      template = bind_locals([])
      @compiled_method_container = template.compiled_method_container
      template.freeze

      if @strict_locals_template
        ActiveSupport::Ractors.make_shareable(@strict_locals_template)
        @templates = nil
      else
        templates = ActiveSupport::Ractors::KeyLockHash.new
        @templates.each_pair do |locals, bound|
          normalized_locals = normalize_locals(locals)
          next if templates[normalized_locals]

          bound.send(:compile_to, @compiled_method_container)
          templates[normalized_locals] = ActiveSupport::Ractors.make_shareable(bound.freeze)
        end
        @templates = templates
      end
      @source.freeze
      @identifier.freeze
      @virtual_path.freeze
      @details.freeze
      @write_lock = nil
      super
    end

    private
      def bind_shared_template(locals)
        normalized_locals = normalize_locals(locals)
        template = @templates[normalized_locals] || ActiveSupport::Ractors.on_main(self) do
          COMPILE_LOCK.synchronize do
            @templates[normalized_locals] || begin
              bound = build_template(normalized_locals)
              bound.send(:compile_to, @compiled_method_container)
              @templates[normalized_locals] = ActiveSupport::Ractors.make_shareable(bound.freeze)
            end
          end
        end

        # Preserve the fast path for non-normalized locals without retaining
        # or freezing the caller's array or strings.
        key = locals.map { |local| local.is_a?(String) ? local.dup : local }.freeze
        @templates[ActiveSupport::Ractors.make_shareable(key)] = template
      end

      def build_bound_template(locals)
        @write_lock.synchronize do
          return @strict_locals_template if @strict_locals_template
          normalized_locals = normalize_locals(locals)

          # We need ||=, both to dedup on the normalized locals and to check
          # while holding the lock.
          template = (@templates[normalized_locals] ||= build_template(normalized_locals))

          if template.strict_locals?
            @strict_locals_template = template
            @templates = { normalized_locals => template }.freeze
          else
            # This may have already been assigned, but we've already de-dup'd so
            # reassignment is fine.
            @templates[locals.dup] = template
          end

          template
        end
      end

      def build_template(locals)
        Template.new(
          @source,
          @identifier,
          details.handler_class,

          format: details.format_or_default,
          variant: variant&.to_s,
          virtual_path: @virtual_path,

          locals: locals.map(&:to_s)
        )
      end

      def normalize_locals(locals)
        locals.map(&:to_sym).sort!.freeze
      end
  end
end
