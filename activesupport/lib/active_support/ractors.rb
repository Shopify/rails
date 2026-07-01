# frozen_string_literal: true

module ActiveSupport
  # Shims for +Ractor+ shareability methods so framework code can call them
  # unconditionally regardless of the Ruby version.
  module Ractors # :nodoc:
    class << self
      attr_accessor :unshareable_proc_action

      # Callbacks run by +Rails::Application#ractorize!+.
      #
      # +before_freeze+ callbacks run *before* the application graph is frozen
      # (make it shareable). Use them to apply behavioral patches (module
      # prepends) and to warm state that would otherwise be lazily memoized onto
      # an object that is about to be frozen.
      #
      # +on_freeze+ callbacks run *after* the application graph is frozen. Use
      # them to freeze/share request-path state that is not reachable from the
      # application object graph (module constants, class variables captured into
      # class ivars, controller class-level state, ...).
      def before_freeze_callbacks
        @before_freeze_callbacks ||= []
      end

      def on_freeze_callbacks
        @on_freeze_callbacks ||= []
      end

      def before_freeze(&block)
        before_freeze_callbacks << block
      end

      def on_freeze(&block)
        on_freeze_callbacks << block
      end

      def run_before_freeze!
        before_freeze_callbacks.each(&:call)
      end

      def run_on_freeze!
        on_freeze_callbacks.each(&:call)
      end

      # Serve a class-level reader that is backed by a class variable (cattr) or
      # a class ivar to non-main Ractors. Class variables can't be read from a
      # non-main Ractor at all, so capture the (effectively-immutable) value into
      # a shareable class ivar on +on_freeze+ and return it from a Ractor.
      def capture_class_reader(mod, name)
        ivar = :"@_ractor_captured_#{name}"
        reader = Module.new
        # Define with a string (not define_method): a method backed by an
        # unshareable Proc can't be called from a non-main Ractor.
        reader.module_eval(<<~RUBY, __FILE__, __LINE__ + 1)
          def #{name}
            return super if Ractor.main?
            #{mod.name}.instance_variable_get(:#{ivar})
          end
        RUBY
        mod.singleton_class.prepend(reader)
        on_freeze do
          value = mod.send(name)
          shareable = begin
            make_shareable(value.dup)
          rescue StandardError, TypeError
            make_shareable(value)
          end
          mod.instance_variable_set(ivar, shareable)
        end
      end

      # Attempt to make a proc shareable. If successful, a shareable proc is returned.
      # If a Ractor::IsolationError is raised, the outcome will depend on how
      # the user's application configuration:
      #
      # :raise - The error is raised
      # :warn  - A deprecation warning is triggered and the original unshareable proc is returned.
      def try_shareable_proc(proc = nil, &block)
        proc ||= block
        return proc unless unshareable_proc_action

        shareable_proc(&proc)
      rescue Ractor::IsolationError
        case unshareable_proc_action
        when :raise
          raise
        when :warn
          ActiveSupport.deprecator.warn(<<~MSG)
            Rails attempted to make a Proc from your application Ractor shareable but a Ractor
            Isolation error was raised. The proc being returned is not Ractor safe and a runtime
            error may occur anytime during the request lifecycle.

            #{proc.inspect}
          MSG

          proc
        end
      end

      if defined?(Ractor) && RUBY_VERSION >= "4.0"
        # Makes +obj+ Ractor-shareable by delegating to +Ractor.make_shareable+.
        #
        # The +copy:+ option is forwarded unchanged. On Ruby versions without
        # +Ractor.make_shareable+, this shim returns +obj+ unchanged.
        def make_shareable(...)
          Ractor.make_shareable(...)
        end

        # Returns whether +obj+ is Ractor-shareable by delegating to
        # +Ractor.shareable?+.
        #
        # On Ruby versions without +Ractor.shareable?+, this shim returns +obj+
        # unchanged.
        def shareable?(obj)
          Ractor.shareable?(obj)
        end

        # Returns a Ractor-shareable proc by delegating to +Ractor.shareable_proc+.
        #
        # The optional +self:+ value is forwarded as the proc's receiver. On Ruby
        # versions without +Ractor.shareable_proc+, this shim returns the block
        # unchanged.
        def shareable_proc(...)
          Ractor.shareable_proc(...)
        end

        # Returns a Ractor-shareable lambda by delegating to
        # +Ractor.shareable_lambda+.
        #
        # The optional +self:+ value is forwarded as the lambda's receiver. On Ruby
        # versions without +Ractor.shareable_lambda+, this shim returns the block
        # unchanged.
        def shareable_lambda(...)
          Ractor.shareable_lambda(...)
        end
      else
        def make_shareable(obj, copy: false)
          obj
        end

        def shareable?(obj)
          obj
        end

        def shareable_proc(self: nil, &block)
          block
        end

        def shareable_lambda(self: nil, &block)
          block
        end
      end
    end
  end
end
