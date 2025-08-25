# frozen_string_literal: true

require "active_support/core_ext/object/duplicable"
require "active_support/core_ext/array/extract"

module ActiveSupport
  class FilterCollection # :nodoc:
    def initialize(parameters: [], attributes: {})
      @parameters = parameters
      @attributes = attributes
      @abstract_models = []
    end

    attr_reader :parameters, :attributes

    def attributes_for(model)
      model.ancestors.inject(@parameters.dup) do |parameters, mod|
        mod.class == Class ? parameters.concat(@attributes[mod].to_a) : parameters
      end
    end

    def define_attributes_for(model, abstract: false, attributes:)
      @abstract_models << model if abstract
      (@attributes[model] ||= []).concat(attributes)
    end

    def compile(attributes: false, regexes: false)
      compile_attributes if attributes
      compile_regexes if regexes
      parameters
    end

    private

    def compile_regexes
      @parameters, patterns = @parameters.partition { |filter| filter.is_a?(Proc) }

      patterns.map! do |pattern|
        pattern.is_a?(Regexp) ? pattern : "(?i:#{Regexp.escape pattern.to_s})"
      end

      deep_patterns = patterns.extract! { |pattern| pattern.to_s.include?("\\.") }

      @parameters << Regexp.new(patterns.join("|")) if patterns.any?
      @parameters << Regexp.new(deep_patterns.join("|")) if deep_patterns.any?
    end

    def compile_attributes
      (@attributes.keys - @abstract_models).inject(@parameters) do |prameters, model|
        prameters.concat(parameters_for(model))
      end
    end

    def parameters_for(model)
      attributes_for(model).map do |attribute|
        "#{model.model_name.element}.#{attribute}"
      end
    end
  end
end
