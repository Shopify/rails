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

      @templates = Concurrent::Map.new(initial_capacity: 2)
      @write_lock = Mutex.new
    end

    def bind_locals(locals)
      if frozen?
        # Post-+make_shareable!+: +@templates+ is a frozen Hash (possibly
        # with a default value from the strict-locals path). Hits return
        # the cached, already-shareable Template. Misses fall through to a
        # local non-cached build; the resulting Template is uncached and
        # will compile a fresh method per call (bounded leak per
        # uncached locals tuple). Pre-warming +@templates+ at boot via
        # +PathRegistry.make_shareable!+ keeps this branch rare in
        # practice.
        @templates[locals] || build_template(normalize_locals(locals))
      elsif template = @templates[locals]
        template
      else
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

          template
        end
      end
    end

    def built_templates # :nodoc:
      @templates.values
    end

    # Cascade target for +FileSystemResolver#make_shareable!+. The
    # +UnboundTemplate+ lives in the resolver's frozen cache and is read
    # from non-main Ractors during +find_all+, so its +instance_variables+
    # must all be shareable.
    #
    # +@templates+ is normally a +Concurrent::Map+ (with embedded locks
    # and Mutex internals) that gets populated lazily by +bind_locals+.
    # We snapshot whatever bindings exist into a frozen +Hash+ and cascade
    # +make_shareable!+ into each cached +Template+ so they can be read
    # post-freeze. The snapshot is what +Resolver#built_templates+ reads
    # for exception backtrace mapping
    # (+ExceptionWrapper#build_backtrace+); leaving it empty would break
    # source-line mapping for production error pages, so callers
    # (+PathRegistry.make_shareable!+) eager-warm the cache before
    # cascading here.
    #
    # +@write_lock+ is dropped to nil; +bind_locals+ branches on
    # +frozen?+ to avoid taking it post-freeze.
    def make_shareable! # :nodoc:
      return self if frozen?

      snapshot =
        if @templates.is_a?(Hash)
          # Strict-locals path already replaced @templates with
          # +Hash.new(template).freeze+; +Hash#dup+ preserves the default
          # value so every locals key continues to return the warmed
          # Template post-freeze.
          @templates.dup
        else
          # Concurrent::Map → plain Hash snapshot.
          h = {}
          @templates.each_pair { |k, v| h[k] = v }
          h
        end

      snapshot.each_value(&:make_shareable!)
      snapshot.default&.make_shareable!

      @templates = snapshot.freeze
      @write_lock = nil

      super
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
