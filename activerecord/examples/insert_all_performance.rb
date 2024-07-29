# frozen_string_literal: true

require 'debug'
require "active_record"
require "benchmark/ips"

GC.disable

ROWS_COUNT = 1000

conn = { adapter: "sqlite3", database: ":memory:" }

ActiveRecord::Base.establish_connection(conn)

class Exhibit < ActiveRecord::Base
  connection.create_table :exhibits, force: true do |t|
    t.string :name, :email, :title, :tags
    t.integer :variant_id, :product_id, :inventory_id, :something_id, :another_id
    t.boolean :fulfilled
    t.datetime :fulfilled_at, :deleted_at
    t.timestamps null: true
  end
end

def db_time(value)
  value.to_formatted_s(:db).inspect
end

ATTRS = {
  name: "sam",
  email: "kirs@shopify.com",
  title: "title",
  tags: "tag1,tag2,tag3",
  variant_id: 1,
  product_id: 1,
  inventory_id: 1,
  something_id: 1,
  another_id: 1,
  fulfilled: true,
  fulfilled_at: Time.now,
  deleted_at: Time.now
}

def build_insert_with_arel(model, columns, values_list)
  s = "INSERT INTO #{model.quoted_table_name} (#{columns.join(',')})"
  s << model.connection.visitor.compile(Arel::Nodes::ValuesList.new(values_list))
  s
end

conn = Exhibit.connection

columns = %w[name email title tags variant_id product_id inventory_id something_id another_id fulfilled fulfilled_at deleted_at created_at updated_at]

rows = begin
  attrs = ATTRS.dup
  attrs[:fulfilled_at] = (attrs[:fulfilled_at]).to_formatted_s(:db)
  attrs[:deleted_at] = (attrs[:deleted_at]).to_formatted_s(:db)
  attrs[:created_at] = (Time.now).to_formatted_s(:db)
  attrs[:updated_at] = attrs[:created_at]

  values = [
    attrs[:name], attrs[:email], attrs[:title], attrs[:tags], attrs[:variant_id], attrs[:product_id], attrs[:inventory_id], attrs[:something_id], attrs[:another_id], attrs[:fulfilled], attrs[:fulfilled_at], attrs[:deleted_at], attrs[:created_at], attrs[:updated_at]
  ]
  [values] * ROWS_COUNT
end

raw_sql = begin
  conn = Exhibit.connection
  values = (1..ROWS_COUNT).map do
    attrs = ATTRS
    "(#{conn.quote(attrs[:name])}, #{conn.quote(attrs[:email])}, #{conn.quote(attrs[:title])}, #{conn.quote(attrs[:tags])}, #{attrs[:variant_id]}, #{attrs[:product_id]}, #{attrs[:inventory_id]}, #{attrs[:something_id]}, #{attrs[:another_id]}, #{attrs[:fulfilled]}, #{db_time(attrs[:fulfilled_at])}, #{db_time(attrs[:deleted_at])}, #{db_time(Time.now)}, #{db_time(Time.now)})"
  end
  "INSERT INTO exhibits (name, email, title, tags, variant_id, product_id, inventory_id, something_id, another_id, fulfilled, fulfilled_at, deleted_at, created_at, updated_at) "\
  "VALUES #{values.join(',')}"
end

relation = Exhibit.all

require 'vernier'
Vernier.profile(out: "time_profile.json") do
  300.times do
    relation.insert_all(
      rows,
      columns: columns,
      typecast: true
    )
  end
end


# Benchmark.ips do |x|
#
#   x.report("raw sql") do
#     conn.execute(raw_sql)
#   end
#
#   x.report("arel") do
#     conn.execute(build_insert_with_arel(Exhibit, columns, rows))
#   end
#
#   x.report("rows no-cast") do
#     relation.insert_all(
#       rows,
#       columns: columns,
#       typecast: false
#     )
#   end
#
#   x.report("rows cast") do
#     relation.insert_all(
#       rows,
#       columns: columns,
#       typecast: true
#     )
#   end
#
#   insert_all_rows = [ATTRS] * ROWS_COUNT
#   x.report("insert_all") do
#     relation.insert_all(insert_all_rows)
#   end
#
#   x.compare!(order: :baseline)
# end
