# frozen_string_literal: true

require "concurrent/map"
require "active_support/core_ext/kernel/ractor_shareability"

module ActionView
  class UnboundTemplate
    attr_reader :virtual_path, :details
    delegate :locale, :format, :variant, :handler, to: :@details

    def initialize(source, identifier, details:, virtual_path:)
      @source = source
      @identifier = identifier
      @details = details
      @virtual_path = virtual_path

      @templates = Concurrent::Map.new(initial_capacity: 2)
      @write_lock = Mutex.new
    end

    def bind_locals(locals)
      if frozen?
        return @templates[locals] || build_template(normalize_locals(locals))
      end

      unless template = @templates[locals]
        @write_lock.synchronize do
          normalized_locals = normalize_locals(locals)

          # We need ||=, both to dedup on the normalized locals and to check
          # while holding the lock.
          template = (@templates[normalized_locals] ||= build_template(normalized_locals))

          if template.strict_locals?
            # Under strict locals, we only need one template.
            # This replaces the @templates Concurrent::Map with a hash which
            # returns this template for every key.
            @templates = Hash.new(template).freeze
          else
            # This may have already been assigned, but we've already de-dup'd so
            # reassignment is fine.
            @templates[locals.dup] = template
          end
        end
      end
      template
    end

    def built_templates # :nodoc:
      @templates.values
    end

    def make_shareable! # :nodoc:
      return self if frozen?

      snapshot = @templates.is_a?(Hash) ? @templates.dup : @templates.each_pair.to_h
      snapshot.each_value { |template| ractor_make_shareable(template) }
      ractor_make_shareable(snapshot.default) if snapshot.default

      @templates = snapshot.freeze
      @write_lock = nil

      ractor_make_shareable(self)
    end

    private
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
