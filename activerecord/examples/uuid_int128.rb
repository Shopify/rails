# frozen_string_literal: true

require "active_record"
require "active_record/connection_adapters/postgresql_adapter"
require "logger"

# =============================================================================
# UuidAsInteger type — maps between Ruby 128-bit Integers and PostgreSQL UUID columns.
#
# Values are exposed to Ruby as Integer and sent to PostgreSQL as UUID strings.
# Columns not opted in keep their normal :uuid behavior.
# =============================================================================
class UuidAsInteger < ActiveModel::Type::Value
  ACCEPTABLE_UUID = ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Uuid::ACCEPTABLE_UUID

  def type
    :uuid_as_integer
  end

  def type_for_database
    :uuid
  end

  # DB string → Ruby Integer
  def deserialize(value)
    return if value.nil?
    value.is_a?(Integer) ? value : uuid_string_to_int(value.to_s)
  end

  # Ruby value → Ruby Integer (when assigning in Ruby)
  def cast(value)
    return if value.nil?

    case value
    when Integer
      value
    when String
      if value.match?(ACCEPTABLE_UUID)
        uuid_string_to_int(value)
      elsif value.match?(/\A-?\d+\z/)
        value.to_i
      elsif value.match?(/\A0x[0-9a-fA-F]+\z/)
        value.to_i(16)
      end
    else
      value.to_i
    end
  end

  # Ruby Integer → UUID string for binding/quoting
  def serialize(value)
    return if value.nil?

    case value
    when Integer
      int_to_uuid_string(value)
    when String
      if value.match?(ACCEPTABLE_UUID)
        format_uuid(value)
      else
        int_to_uuid_string(value.to_i)
      end
    else
      int_to_uuid_string(value.to_i)
    end
  end

  def changed?(old_value, new_value, _new_value_before_type_cast)
    old_value != new_value
  end

  def changed_in_place?(raw_old_value, new_value)
    deserialize(raw_old_value) != new_value
  end

  private
    def uuid_string_to_int(uuid)
      hex = uuid.delete("-")
      return nil unless hex.match?(/\A[0-9a-fA-F]{32}\z/)
      hex.to_i(16)
    end

    def int_to_uuid_string(int)
      hex = int.to_s(16).rjust(32, "0")
      "#{hex[0..7]}-#{hex[8..11]}-#{hex[12..15]}-#{hex[16..19]}-#{hex[20..31]}"
    end

    def format_uuid(uuid)
      uuid = uuid.delete("{}-").downcase
      "#{uuid[..7]}-#{uuid[8..11]}-#{uuid[12..15]}-#{uuid[16..19]}-#{uuid[20..]}"
    end
end

# On PostgreSQL: Integer ↔ UUID conversion
ActiveRecord::Type.register(:uuid_as_integer, UuidAsInteger, adapter: :postgresql)

# On Trilogy (MySQL): noop — column is already a bigint/integer,
# so just behave like a normal BigInteger type.
ActiveRecord::Type.register(:uuid_as_integer, ActiveRecord::Type::BigInteger, adapter: :trilogy)

# =============================================================================
# Minimal TrustedId reproduction (from component gem)
# =============================================================================
class TrustedId
  include Comparable

  attr_reader :db_id
  alias_method :to_int, :db_id
  alias_method :to_i, :db_id

  def self.type_check(id)
    raise TypeError, "id value of wrong type #{id.class} (expected #{self})" unless id.is_a?(self)
  end

  def initialize(db_id)
    raise TypeError, "db_id of wrong type #{db_id.class} (expected Integer)" unless db_id.is_a?(Integer)
    raise ArgumentError, "db_id must be greater than 0" unless db_id > 0
    @db_id = db_id
  end

  def ==(other)
    other.is_a?(self.class) && other.db_id == db_id
  end
  alias_method :eql?, :==

  def hash
    @hash ||= self.class.hash | db_id.hash
  end

  def to_s = db_id.to_s
  def inspect = "#<#{self.class} db_id=#{db_id}>"

  def <=>(other)
    db_id <=> other.db_id if other.is_a?(self.class)
  end
end

class ShopId < TrustedId; end
class ResourceLimitId < TrustedId; end

module TrustedIdAttributes
  def self.extended(model)
    model.class_attribute(:trusted_id_attributes, default: {}, instance_accessor: false)
    model.singleton_class.send(:public, :trusted_id_attributes)
    model.singleton_class.send(:private, :trusted_id_attributes=)
  end

  def trusted_id_attribute(attr_name, id_class = TrustedId, attribute: attr_name)
    self.trusted_id_attributes = trusted_id_attributes.merge(attr_name => id_class)
    trusted_ivar_name = "@_trusted_#{attr_name}"

    if attribute == :id
      class_eval(<<-RUBY, __FILE__, __LINE__ + 1)
        def trusted_#{attr_name}
          db_id = id
          return nil unless db_id
          return #{trusted_ivar_name} if #{trusted_ivar_name}&.db_id == db_id
          #{trusted_ivar_name} = #{id_class}.new(db_id)
        end
      RUBY
    else
      class_eval(<<-RUBY, __FILE__, __LINE__ + 1)
        def trusted_#{attr_name}
          db_id = #{attribute}
          return nil unless db_id
          return #{trusted_ivar_name} if #{trusted_ivar_name}&.db_id == db_id
          #{trusted_ivar_name} = #{id_class}.new(db_id)
        end
      RUBY
    end
  end

  def trusted_scope(id_column, ids, trusted_id_filters = nil)
    raise ArgumentError unless trusted_id_attributes.keys.include?(id_column)

    if trusted_id_filters.blank?
      [ids].flatten(1).each { |id| TrustedId.type_check(id) }
      where(id_column => ids)
    else
      conditions = {}
      trusted_id_filters.each do |filter_name, filter_id|
        raise ArgumentError unless trusted_id_attributes.keys.include?(filter_name)
        TrustedId.type_check(filter_id)
        conditions[filter_name] = filter_id.db_id
      end
      conditions[id_column] = ids
      where(conditions)
    end
  end
end

# =============================================================================
# Connect and set up schema
# =============================================================================
ActiveRecord::Base.establish_connection(
  adapter:    "postgresql",
  host:       ENV.fetch("PGHOST", "postgres.shared.shared.dev.internal"),
  port:       ENV.fetch("PGPORT", 5432),
  username:   ENV.fetch("PGUSER", "postgres"),
  password:   ENV.fetch("PGPASSWORD", nil),
  database:   ENV.fetch("PGDATABASE", "uuid_int128_test"),
  gssencmode: ENV.fetch("PGGSSENCMODE", "disable"),
)

ActiveRecord::Base.logger = Logger.new($stdout)
ActiveRecord::Base.logger.level = Logger::DEBUG

conn = ActiveRecord::Base.lease_connection

begin
  conn.execute("SELECT 1")
rescue ActiveRecord::NoDatabaseError
  puts "Creating database uuid_int128_test..."
  ActiveRecord::Base.establish_connection(
    adapter:    "postgresql",
    host:       ENV.fetch("PGHOST", "postgres.shared.shared.dev.internal"),
    port:       ENV.fetch("PGPORT", 5432),
    username:   ENV.fetch("PGUSER", "postgres"),
    password:   ENV.fetch("PGPASSWORD", nil),
    database:   "postgres",
    gssencmode: ENV.fetch("PGGSSENCMODE", "disable"),
  )
  ActiveRecord::Base.lease_connection.create_database("uuid_int128_test")
  ActiveRecord::Base.establish_connection(
    adapter:    "postgresql",
    host:       ENV.fetch("PGHOST", "postgres.shared.shared.dev.internal"),
    port:       ENV.fetch("PGPORT", 5432),
    username:   ENV.fetch("PGUSER", "postgres"),
    password:   ENV.fetch("PGPASSWORD", nil),
    database:   "uuid_int128_test",
    gssencmode: ENV.fetch("PGGSSENCMODE", "disable"),
  )
  conn = ActiveRecord::Base.lease_connection
end

conn.execute("DROP TABLE IF EXISTS resource_limits")
conn.execute(<<~SQL)
  CREATE TABLE resource_limits (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    shop_id uuid NOT NULL,
    resource varchar(255) DEFAULT NULL,
    "limit" bigint DEFAULT NULL,
    some_externally_facing_uuid uuid DEFAULT NULL,
    PRIMARY KEY (id)
  )
SQL

# =============================================================================
# Model: opt in per-column with `attribute`
# =============================================================================
class ResourceLimit < ActiveRecord::Base
  attribute :id, :uuid_as_integer
  attribute :shop_id, :uuid_as_integer
  # some_externally_facing_uuid stays as default :uuid

  extend TrustedIdAttributes
  trusted_id_attribute :id, ResourceLimitId
  trusted_id_attribute :shop_id, ShopId
end

# =============================================================================
# Demo
# =============================================================================
puts "=" * 60
puts "SCHEMA"
puts "=" * 60
ResourceLimit.columns.each do |col|
  puts "  %-45s sql_type=%-10s ar_type=%s" % [col.name, col.sql_type, ResourceLimit.type_for_attribute(col.name).type]
end
puts

puts "=" * 60
puts "INSERT: integers as id/shop_id, real uuid for the external one"
puts "=" * 60
row = ResourceLimit.create!(
  id:       1,
  shop_id:  42,
  resource: "products",
  limit:    1000,
  some_externally_facing_uuid: "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"
)
puts "row.id              = #{row.id.inspect}  (#{row.id.class})"
puts "row.shop_id         = #{row.shop_id.inspect}  (#{row.shop_id.class})"
puts "row.some_externally_facing_uuid = #{row.some_externally_facing_uuid.inspect}"
puts

puts "=" * 60
puts "RELOAD from DB"
puts "=" * 60
row.reload
puts "row.id              = #{row.id.inspect}  (#{row.id.class})"
puts "row.shop_id         = #{row.shop_id.inspect}  (#{row.shop_id.class})"
puts "row.some_externally_facing_uuid = #{row.some_externally_facing_uuid.inspect}"
puts

puts "=" * 60
puts "FIND by integer id"
puts "=" * 60
found = ResourceLimit.find(1)
puts "ResourceLimit.find(1) => id=#{found.id.inspect}, shop_id=#{found.shop_id.inspect}"
puts

puts "=" * 60
puts "WHERE shop_id = 42"
puts "=" * 60
results = ResourceLimit.where(shop_id: 42)
puts "Found #{results.count} row(s)"
results.each do |r|
  puts "  id=#{r.id.inspect} shop_id=#{r.shop_id.inspect} resource=#{r.resource.inspect}"
end
puts

puts "=" * 60
puts "Large 128-bit integer ID"
puts "=" * 60
big_id = (2**128) - 1
row2 = ResourceLimit.create!(
  id:       big_id,
  shop_id:  (2**64),
  resource: "orders",
  limit:    999,
)
puts "Created with id=#{big_id}"
puts "row2.id      = #{row2.id.inspect}"
puts "row2.shop_id = #{row2.shop_id.inspect}"
row2.reload
puts "After reload:"
puts "row2.id      = #{row2.id.inspect}"
puts "row2.shop_id = #{row2.shop_id.inspect}"
found2 = ResourceLimit.find(big_id)
puts "ResourceLimit.find(2**128 - 1) => id=#{found2.id.inspect}"
puts

puts "=" * 60
puts "Assign UUID string to int128 column"
puts "=" * 60
row3 = ResourceLimit.new
row3.id = "00000000-0000-0000-0000-000000000099"
row3.shop_id = "00000000-0000-0000-0000-0000000000ff"
row3.resource = "themes"
row3.save!
puts "row3.id      = #{row3.id.inspect}  (#{row3.id.class})"
puts "row3.shop_id = #{row3.shop_id.inspect}  (#{row3.shop_id.class})"
puts

puts "=" * 60
puts "RAW SQL: what PG actually has"
puts "=" * 60
raw = conn.execute("SELECT id, shop_id, resource, some_externally_facing_uuid FROM resource_limits ORDER BY resource")
raw.each { |r| puts "  #{r.inspect}" }
puts

puts "=" * 60
puts "TrustedId DSL COMPATIBILITY"
puts "=" * 60
row = ResourceLimit.find(1)
puts "row.id                    = #{row.id.inspect} (#{row.id.class})"
puts "row.trusted_id            = #{row.trusted_id.inspect} (#{row.trusted_id.class})"
puts "row.trusted_id.db_id      = #{row.trusted_id.db_id.inspect} (#{row.trusted_id.db_id.class})"
puts "row.trusted_shop_id       = #{row.trusted_shop_id.inspect} (#{row.trusted_shop_id.class})"
puts "row.trusted_shop_id.db_id = #{row.trusted_shop_id.db_id.inspect}"
puts

puts "trusted_scope(:shop_id, ShopId.new(42)):"
ResourceLimit.trusted_scope(:shop_id, ShopId.new(42)).each do |r|
  puts "  id=#{r.id.inspect} shop_id=#{r.shop_id.inspect} resource=#{r.resource.inspect}"
end
puts

puts "trusted_scope(:id, [1, 153], { shop_id: ShopId.new(42) }):"
ResourceLimit.trusted_scope(:id, [1, 153], { shop_id: ShopId.new(42) }).each do |r|
  puts "  id=#{r.id.inspect} shop_id=#{r.shop_id.inspect} resource=#{r.resource.inspect}"
end
puts

big_id = (2**128) - 1
trusted_big = ResourceLimitId.new(big_id)
puts "TrustedId with 128-bit: #{trusted_big.inspect}"
found = ResourceLimit.find(trusted_big.db_id)
puts "ResourceLimit.find(trusted_big.db_id) => id=#{found.id.inspect}"
puts "found.trusted_id          = #{found.trusted_id.inspect}"
puts "found.trusted_id.db_id    = #{found.trusted_id.db_id.inspect}"
puts

puts "trusted_scope(:id, ResourceLimitId.new(2**128 - 1)):"
ResourceLimit.trusted_scope(:id, ResourceLimitId.new(big_id)).each do |r|
  puts "  id=#{r.id.inspect} shop_id=#{r.shop_id.inspect} resource=#{r.resource.inspect}"
end
puts

puts "Done!"
