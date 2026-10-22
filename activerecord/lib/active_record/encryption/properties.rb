# frozen_string_literal: true

# :markup: markdown
module ActiveRecord
  module Encryption
    # This is a wrapper for a hash of encryption properties. It is used by
    # `Key` (public tags) and `Message` (headers).
    #
    # Since properties are serialized in messages, it is important for storage
    # efficiency to keep their keys as short as possible. It defines accessors
    # for common properties that will keep these keys very short while exposing
    # a readable name.
    #
    # ```
    # message.headers.encrypted_data_key # instead of message.headers[:k]
    # ```
    #
    # See Key, Message
    class Properties
      ALLOWED_VALUE_CLASSES = [String, ActiveRecord::Encryption::Message, Numeric, Integer, Float, BigDecimal, TrueClass, FalseClass, Symbol, NilClass].freeze

      delegate_missing_to :data
      delegate :==, :[], :each, :key?, to: :data

      def encrypted_data_key = self[:k]

      def encrypted_data_key=(value)
        self[:k] = value
      end

      def encrypted_data_key_id = self[:i]

      def encrypted_data_key_id=(value)
        self[:i] = value
      end

      def compressed = self[:c]

      def compressed=(value)
        self[:c] = value
      end

      def iv = self[:iv]

      def iv=(value)
        self[:iv] = value
      end

      def auth_tag = self[:at]

      def auth_tag=(value)
        self[:at] = value
      end

      def encoding = self[:e]

      def encoding=(value)
        self[:e] = value
      end

      def initialize(initial_properties = {})
        @data = {}
        add(initial_properties)
      end

      # Set a value for a given key
      #
      # It will raise an `EncryptedContentIntegrity` if the value exists
      def []=(key, value)
        raise Errors::EncryptedContentIntegrity, "Properties can't be overridden: #{key}" if key?(key)
        validate_value_type(value)
        data[key] = value
      end

      def validate_value_type(value)
        unless ALLOWED_VALUE_CLASSES.include?(value.class) || ALLOWED_VALUE_CLASSES.any? { |klass| value.is_a?(klass) }
          raise ActiveRecord::Encryption::Errors::ForbiddenClass, "Can't store a #{value.class}, only properties of type #{ALLOWED_VALUE_CLASSES.inspect} are allowed"
        end
      end

      def add(other_properties)
        other_properties.each do |key, value|
          self[key.to_sym] = value
        end
      end

      def to_h
        data
      end

      private
        attr_reader :data
    end
  end
end
