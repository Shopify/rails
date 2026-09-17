# frozen_string_literal: true

module ActiveRecord::Associations
  module ForeignAssociation # :nodoc:
    def foreign_key_present?
      if reflection.klass.primary_key
        ActiveRecord::Key.for(reflection.active_record_primary_key).all? do |key|
          owner.attribute_present?(key)
        end
      else
        false
      end
    end

    def nullified_owner_attributes
      Hash.new.tap do |attrs|
        ActiveRecord::Key.for(reflection.foreign_key).each { |foreign_key| attrs[foreign_key] = nil }
        attrs[reflection.type] = nil if reflection.type.present?
      end
    end

    private
      # Sets the owner attributes on the given record
      def set_owner_attributes(record)
        return if options[:through]

        reflection.association_route(origin_class: owner.class, destination_class: record.class).write(owner, record)
      end
  end
end
