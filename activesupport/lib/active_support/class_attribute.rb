# frozen_string_literal: true

require "active_support/core_ext/object/shareable"

module ActiveSupport
  module ClassAttribute # :nodoc:
    class << self
      # Defines reader/writer methods for a class-level attribute. Storage
      # lives in instance variables on the relevant singleton classes (rather
      # than in a closure local), so the generated methods don't capture
      # mutable state and can be made Ractor-shareable.
      def redefine(owner, name, namespaced_name, value)
        ivar = :"@#{namespaced_name}"

        if owner.singleton_class?
          # +owner+ is itself a singleton class. Write +value+ to the
          # attached object's ivar so the shadow reader (which calls
          # +singleton_class.instance_variable_get(ivar)+ on the attached
          # object's +self+) finds it.
          owner.instance_variable_set(ivar, value)

          if owner.attached_object.is_a?(Module)
            define_singleton_shadow_reader(owner, namespaced_name, ivar, private: true)
          else
            define_singleton_shadow_reader(owner, name, ivar)
          end
        end

        # Storage on +owner.singleton_class+ supports the inheritance chain
        # used by the namespaced reader below: a subclass that hasn't set
        # the attribute falls through to its superclass's stored value via
        # +superclass.send(namespaced_name)+.
        owner.singleton_class.instance_variable_set(ivar, value)

        define_namespaced_reader(owner.singleton_class, namespaced_name, ivar)
        define_namespaced_writer(owner.singleton_class, owner, name, namespaced_name, ivar)
      end

      private
        # Reader installed directly on +owner+ when +owner+ is a singleton
        # class. The body reads the value out of the receiver's own
        # singleton class ivar at call time.
        def define_singleton_shadow_reader(owner, name, ivar, private: false)
          owner.silence_redefinition_of_method(name)
          # Captures only +ivar+ (a frozen Symbol).
          reader = -> { singleton_class.instance_variable_get(ivar) }
          reader.make_shareable!
          owner.define_method(name, reader)
          owner.send(:private, name) if private
        end

        # Namespaced reader on +owner.singleton_class+. Looks up +ivar+ on
        # the receiver's own singleton class first; otherwise delegates to
        # the superclass so subclasses inherit values from their ancestors.
        def define_namespaced_reader(target, namespaced_name, ivar)
          target.silence_redefinition_of_method(namespaced_name)
          # Captures only +namespaced_name+ and +ivar+ (frozen Symbols).
          reader = -> {
            if singleton_class.instance_variable_defined?(ivar)
              singleton_class.instance_variable_get(ivar)
            else
              superclass.send(namespaced_name)
            end
          }
          reader.make_shareable!
          target.define_method(namespaced_name, reader)
          target.send(:private, namespaced_name)
        end

        # Namespaced writer on +owner.singleton_class+. When invoked on
        # +owner+ itself, writes the value to +owner+'s singleton class.
        # When invoked on a different receiver (a subclass, or a per-instance
        # singleton class), recurses so the receiver gets its own shadow
        # reader and storage location.
        def define_namespaced_writer(target, owner, name, namespaced_name, ivar)
          writer_name = :"#{namespaced_name}="
          target.silence_redefinition_of_method(writer_name)
          # Captures +owner+ (a Class, shareable) and +name+/+namespaced_name+/+ivar+
          # (frozen Symbols).
          writer = ->(value) {
            if owner.equal?(self)
              singleton_class.instance_variable_set(ivar, value)
            else
              ::ActiveSupport::ClassAttribute.redefine(self, name, namespaced_name, value)
            end
          }
          writer.make_shareable!
          target.define_method(writer_name, writer)
          target.send(:private, writer_name)
        end
    end
  end
end
