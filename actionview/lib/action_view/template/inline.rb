# frozen_string_literal: true

module ActionView # :nodoc:
  class Template # :nodoc:
    class Inline < Template # :nodoc:
      # This finalizer is needed (and exactly with a proc inside another proc)
      # otherwise templates leak in development.
      #
      # +shareable_proc+ detaches the captured scope so the constant
      # +Finalizer+ is safe to read from non-main Ractors. The inner proc is
      # a plain +proc+ (not isolated) because +ObjectSpace.define_finalizer+
      # requires an ordinary proc - it derives a binding from the proc and
      # rejects isolated procs with +ArgumentError: Can't create Binding from
      # isolated Proc+.
      Finalizer = shareable_proc do |method_name, mod| # :nodoc:
        proc do
          mod.module_eval do
            remove_possible_method method_name
          end
        end
      end

      def compile(mod)
        super
        ObjectSpace.define_finalizer(self, Finalizer[method_name, mod])
      end
    end
  end
end
