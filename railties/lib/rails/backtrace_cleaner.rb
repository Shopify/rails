# frozen_string_literal: true

require "active_support/backtrace_cleaner"
require "active_support/core_ext/string/access"

module Rails
  class BacktraceCleaner < ActiveSupport::BacktraceCleaner # :nodoc:
    RENDER_TEMPLATE_PATTERN = /:in [`'].*_\w+_{2,3}\d+_\d+'/

    def initialize
      super
      root = ractor_make_shareable(Rails.root && "#{Rails.root}/")
      add_filter(&ractor_shareable_proc do |line|
        # We may be called before Rails.root is assigned.
        # When that happens we fallback to not truncating.
        current_root = root || (Rails.root && "#{Rails.root}/")
        current_root && line.start_with?(current_root) ? line.from(current_root.size) : line
      end)
      add_filter(&ractor_shareable_proc do |line|
        if RENDER_TEMPLATE_PATTERN.match?(line)
          line.sub(RENDER_TEMPLATE_PATTERN, "")
        else
          line
        end
      end)

      add_silencer(&ractor_shareable_proc do |line|
        line.start_with?(File::SEPARATOR, "vendor/", "bin/")
      end)
    end

    def clean(backtrace, kind = :silent)
      return backtrace if ENV["BACKTRACE"]

      super(backtrace, kind)
    end
    alias_method :filter, :clean

    def clean_frame(frame, kind = :silent)
      return frame if ENV["BACKTRACE"]

      super(frame, kind)
    end
  end
end
