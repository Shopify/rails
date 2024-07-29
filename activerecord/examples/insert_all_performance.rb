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

def insert_with_arel
  conn = Exhibit.connection
  columns = %w[name email title tags variant_id product_id inventory_id something_id another_id fulfilled fulfilled_at deleted_at created_at updated_at]
  attrs = ATTRS.dup
  attrs[:fulfilled_at] = (attrs[:fulfilled_at]).to_formatted_s(:db)
  attrs[:deleted_at] = (attrs[:deleted_at]).to_formatted_s(:db)
  attrs[:created_at] = (Time.now).to_formatted_s(:db)
  attrs[:updated_at] = (Time.now).to_formatted_s(:db)
  sql = build_insert_with_arel(Exhibit, columns, [attrs.values] * ROWS_COUNT)
  conn.execute(sql)
end

Benchmark.ips do |x|
  x.warmup = 2
  x.time   = 4

  relation = Exhibit.all

  x.report("insert_all") do
    conn = Exhibit.connection

    relation.insert_all(
      [ATTRS] * ROWS_COUNT
    )
  end

  x.report("insert_all with columns without typecast") do
    conn = Exhibit.connection
    attrs = ATTRS.dup
    attrs[:fulfilled_at] = (attrs[:fulfilled_at]).to_formatted_s(:db)
    attrs[:deleted_at] = (attrs[:deleted_at]).to_formatted_s(:db)
    attrs[:created_at] = (Time.now).to_formatted_s(:db)
    attrs[:updated_at] = attrs[:created_at]

    values = [
      attrs[:name], attrs[:email], attrs[:title], attrs[:tags], attrs[:variant_id], attrs[:product_id], attrs[:inventory_id], attrs[:something_id], attrs[:another_id], attrs[:fulfilled], attrs[:fulfilled_at], attrs[:deleted_at], attrs[:created_at], attrs[:updated_at]
    ]

    relation.insert_all(
      [values] * ROWS_COUNT,
      columns: %w[name email title tags variant_id product_id inventory_id something_id another_id fulfilled fulfilled_at deleted_at created_at updated_at],
      typecast: false
    )
  end


  x.report("insert_all with columns with typecasting") do
    conn = Exhibit.connection
    attrs = ATTRS.dup
    attrs[:fulfilled_at] = (attrs[:fulfilled_at]).to_formatted_s(:db)
    attrs[:deleted_at] = (attrs[:deleted_at]).to_formatted_s(:db)
    attrs[:created_at] = (Time.now).to_formatted_s(:db)
    attrs[:updated_at] = attrs[:created_at]

    values = [
      attrs[:name], attrs[:email], attrs[:title], attrs[:tags], attrs[:variant_id], attrs[:product_id], attrs[:inventory_id], attrs[:something_id], attrs[:another_id], attrs[:fulfilled], attrs[:fulfilled_at], attrs[:deleted_at], attrs[:created_at], attrs[:updated_at]
    ]

    relation.insert_all(
      [values] * ROWS_COUNT,
      columns: %w[name email title tags variant_id product_id inventory_id something_id another_id fulfilled fulfilled_at deleted_at created_at updated_at],
      typecast: true
    )
  end

  x.report("raw sql") do
    conn = Exhibit.connection
    values = (1..ROWS_COUNT).map do
      attrs = ATTRS
      "(#{conn.quote(attrs[:name])}, #{conn.quote(attrs[:email])}, #{conn.quote(attrs[:title])}, #{conn.quote(attrs[:tags])}, #{attrs[:variant_id]}, #{attrs[:product_id]}, #{attrs[:inventory_id]}, #{attrs[:something_id]}, #{attrs[:another_id]}, #{attrs[:fulfilled]}, #{db_time(attrs[:fulfilled_at])}, #{db_time(attrs[:deleted_at])}, #{db_time(Time.now)}, #{db_time(Time.now)})"
    end

    conn.execute(
      "INSERT INTO exhibits (name, email, title, tags, variant_id, product_id, inventory_id, something_id, another_id, fulfilled, fulfilled_at, deleted_at, created_at, updated_at) "\
      "VALUES #{values.join(',')}"
    )
  end

  x.report("with Arel") do
    insert_with_arel
  end

  x.compare!
end
