# frozen_string_literal: true

module ActiveModel
  module Type
    class Model < Value # :nodoc:
      module NullSerializer
        extend self

        def encode(value)
          value
        end

        def decode(value)
          value
        end
      end

      def initialize(**options)
        @class_name = options.delete(:class_name)
        @serializer = options.delete(:serializer) || NullSerializer
        super
      end

      def changed_in_place?(raw_old_value, value)
        if (old_value = deserialize(raw_old_value))
          old_value.attributes != value.attributes
        else
          !value.nil?
        end
      end

      def valid_value?(value)
        return valid_hash?(value) if value.is_a?(Hash)

        value.is_a?(klass)
      end

      def type
        :model
      end

      def serializable?(value)
        value.is_a?(klass)
      end

      def serialize(value)
        return nil if value.nil?

        serializer.encode(value.attributes_for_database)
      end

      def deserialize(value)
        return nil if value.nil?

        attributes = serializer.decode(value)
        klass.new(attributes)
      end

      private
        attr_reader :serializer

        def valid_hash?(value)
          value = value.transform_keys { |key| klass.attribute_alias(key) || key }

          value.keys.map(&:to_s).difference(klass.attribute_names).none?
        end

        def klass
          @_model_type_class ||= @class_name.constantize
        end

        def cast_value(value)
          case value
          when klass
            value
          when Hash
            klass.new(value)
          else
            klass.new(value.attributes)
          end
        end
    end
  end
end
