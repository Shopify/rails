# frozen_string_literal: true

require "concurrent/map"

module ActionView
  class UnboundTemplate
    attr_reader :virtual_path, :details
    delegate :locale, :format, :variant, :handler, to: :@details

    def initialize(source, identifier, details:, virtual_path:)
      @source = source
      @identifier = identifier
      @details = details
      @virtual_path = virtual_path

      # Strict templates ignore the locals passed at render time, so a single
      # template serves every key. @strict_locals_template holds that one
      # template once we've discovered the template is strict; until then
      # @templates caches one template per set of locals.
      @strict_locals_template = nil
      @templates = Concurrent::Map.new(initial_capacity: 2)
      @write_lock = Mutex.new
    end

    def bind_locals(locals)
      @strict_locals_template || @templates[locals] || build_bound_template(locals)
    end

    def built_templates # :nodoc:
      @strict_locals_template ? [@strict_locals_template] : @templates.values
    end

    def freeze # :nodoc:
      # Ensure at least one template is built so a strict template collapses to
      # @strict_locals_template before we freeze.
      bind_locals([])
      @source.freeze
      @identifier.freeze
      @virtual_path.freeze
      @details.freeze
      if @strict_locals_template
        # Strict templates ignore render-time locals, so a single template
        # serves every key and is fully shareable.
        @strict_locals_template.freeze
        @templates = nil
      else
        # Non-strict templates compile a distinct method per locals set, which
        # a worker Ractor can't do against the frozen shared container. Freeze
        # the boot-compiled variants; only those locals combinations are
        # available after sharing (partials with new locals would need to
        # compile and are unsupported on a frozen template).
        @templates = @templates.each_pair.to_h
        @templates.each_value(&:freeze)
        @templates.freeze
      end
      @write_lock = nil
      super
    end

    private
      def build_bound_template(locals)
        if frozen?
          return @strict_locals_template || @templates[locals] || @templates[normalize_locals(locals)]
        end

        @write_lock.synchronize do
          return @strict_locals_template if @strict_locals_template
          normalized_locals = normalize_locals(locals)

          # We need ||=, both to dedup on the normalized locals and to check
          # while holding the lock.
          template = (@templates[normalized_locals] ||= build_template(normalized_locals))

          if template.strict_locals?
            @strict_locals_template = template
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
