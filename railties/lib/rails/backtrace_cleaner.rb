# frozen_string_literal: true

require "active_support/backtrace_cleaner"
require "active_support/core_ext/string/access"

module Rails
  class BacktraceCleaner < ActiveSupport::BacktraceCleaner # :nodoc:
    RENDER_TEMPLATE_PATTERN = /:in [`'].*_\w+_{2,3}\d+_\d+'/
    private_constant :RENDER_TEMPLATE_PATTERN

    # Default filter/silencer procs are defined at class-body level so their
    # +self+ is the +BacktraceCleaner+ class (which is shareable). They are
    # made shareable at load time so a frozen +BacktraceCleaner+ instance can
    # be reachable from non-main Ractors.

    # Strips the +Rails.root+ prefix from a backtrace line. +Rails.root+ is
    # resolved at filter-call time so the filter remains correct even when it
    # is invoked before +Rails.root+ has been assigned. The result is the
    # original line in that case. The filter only runs on the exception path,
    # not on the request hot path, so recomputing the prefix per call is fine.
    ROOT_PATH_FILTER = ->(line) {
      root = Rails.root
      if root
        prefix = "#{root}/"
        line.start_with?(prefix) ? line.from(prefix.size) : line
      else
        line
      end
    }.make_shareable!
    private_constant :ROOT_PATH_FILTER

    RENDER_TEMPLATE_FILTER = ->(line) {
      if RENDER_TEMPLATE_PATTERN.match?(line)
        line.sub(RENDER_TEMPLATE_PATTERN, "")
      else
        line
      end
    }.make_shareable!
    private_constant :RENDER_TEMPLATE_FILTER

    BUILTIN_PATH_SILENCER = ->(line) {
      line.start_with?(File::SEPARATOR, "vendor/", "bin/")
    }.make_shareable!
    private_constant :BUILTIN_PATH_SILENCER

    def initialize
      super
      add_filter(&ROOT_PATH_FILTER)
      add_filter(&RENDER_TEMPLATE_FILTER)
      add_silencer(&BUILTIN_PATH_SILENCER)
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
