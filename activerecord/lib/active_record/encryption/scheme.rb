# frozen_string_literal: true

module ActiveRecord
  module Encryption
    # A container of attribute encryption options.
    #
    # It validates and serves attribute encryption options.
    #
    # See EncryptedAttributeType, Context
    class Scheme
      attr_accessor :previous_schemes

      def initialize(key_provider: nil, key: nil, deterministic: nil, support_unencrypted_data: nil, downcase: nil, ignore_case: nil,
                     previous_schemes: nil, compress: true, compressor: nil, **context_properties)
        # Initializing all attributes to +nil+ as we want to allow a "not set" semantics so that we
        # can merge schemes without overriding values with defaults. See +#merge+

        @key_provider_param = key_provider
        @key = key
        @deterministic = deterministic
        @support_unencrypted_data = support_unencrypted_data
        @downcase = downcase || ignore_case
        @ignore_case = ignore_case
        @previous_schemes_param = previous_schemes
        @previous_schemes = Array.wrap(previous_schemes)
        @context_properties = context_properties
        @compress = compress
        @compressor = compressor

        validate_config!

        @context_properties[:encryptor] = Encryptor.new(compress: @compress) unless @compress
        @context_properties[:encryptor] = Encryptor.new(compressor: compressor) if compressor

        # Eagerly resolve the lazy +@key_provider_from_key+ and
        # +@deterministic_key_provider+ memos that +key_provider+ falls
        # through. Each was previously a +||=+ pattern (lines 91, 97); when
        # the caller provided neither +key:+ nor +deterministic:+ those
        # right-hand sides evaluate to +nil+, but +||=+ on an undefined ivar
        # still writes +nil+ on every call. Once the +Scheme+ is reachable
        # from a deep-frozen +EncryptedAttributeType+ (the AR attribute_types
        # graph deep-freezes everything reachable at +ractorize!+), that
        # write raises +FrozenError+ on every non-main decrypt. Compute the
        # values once, here, while the +Scheme+ is still mutable.
        @key_provider_from_key = @key.present? ? DerivedSecretKeyProvider.new(@key) : nil
        @deterministic_key_provider = @deterministic ? DeterministicKeyProvider.new(ActiveRecord::Encryption.config.deterministic_key) : nil
      end

      def ignore_case?
        @ignore_case
      end

      def downcase?
        @downcase
      end

      def deterministic?
        !!@deterministic
      end

      def support_unencrypted_data?
        @support_unencrypted_data.nil? ? ActiveRecord::Encryption.config.support_unencrypted_data : @support_unencrypted_data
      end

      def fixed?
        # by default deterministic encryption is fixed
        @fixed ||= @deterministic && (!@deterministic.is_a?(Hash) || @deterministic[:fixed])
      end

      def key_provider
        @key_provider_param || key_provider_from_key || deterministic_key_provider || default_key_provider
      end

      def merge(other_scheme)
        self.class.new(**to_h, **other_scheme.to_h)
      end

      def to_h
        { key_provider: @key_provider_param, deterministic: @deterministic, downcase: @downcase, ignore_case: @ignore_case,
          previous_schemes: @previous_schemes_param, **@context_properties }.compact
      end

      def with_context(&block)
        if @context_properties.present?
          ActiveRecord::Encryption.with_encryption_context(**@context_properties, &block)
        else
          block.call
        end
      end

      def compatible_with?(other_scheme)
        deterministic? == other_scheme.deterministic?
      end

      private
        def validate_config!
          raise Errors::Configuration, "ignore_case: can only be used with deterministic encryption" if @ignore_case && !@deterministic
          raise Errors::Configuration, "key_provider: and key: can't be used simultaneously" if @key_provider_param && @key
          raise Errors::Configuration, "compressor: can't be used with compress: false" if !@compress && @compressor
          raise Errors::Configuration, "compressor: can't be used with encryptor" if @compressor && @context_properties[:encryptor]
        end

        # Eagerly populated in +initialize+ so the +Scheme+ remains
        # immutable post-+ractorize!+ deep-freeze. See the note in
        # +#initialize+ for the +||=+/FrozenError pairing this avoids.
        attr_reader :key_provider_from_key, :deterministic_key_provider

        def default_key_provider
          ActiveRecord::Encryption.key_provider
        end
    end
  end
end
