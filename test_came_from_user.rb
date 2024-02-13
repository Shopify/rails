# frozen_string_literal: true

require "bundler/inline"

gemfile(true) do
  source "https://rubygems.org"

  git_source(:github) { |repo| "https://github.com/#{repo}.git" }

  gem "rails", path: "."

  gem "sqlite3"
  gem "debug"
end

require "debug"
require "active_record"
require "minitest/autorun"
require "logger"

# This connection will do for database-independent bug reports.
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Base.logger = Logger.new(STDOUT)

ActiveRecord::Schema.define do
  create_table :people, force: true do |t|
    t.string :name
    t.integer :age
  end
end

class Person < ActiveRecord::Base
end

class BugTest < Minitest::Test
  def test_dup_does_not_change_attribute_value_type
    person = Person.new(name: "Nikita")

    assert_predicate person, :name_came_from_user?
    refute_predicate person, :age_came_from_user?

    person_dup = person.dup

    assert_predicate person_dup, :name_came_from_user?
    refute_predicate person_dup, :age_came_from_user?
  end

  def test_clone_does_not_change_attribute_value_type
    person = Person.new(name: "Nikita")

    assert_predicate person, :name_came_from_user?
    refute_predicate person, :age_came_from_user?

    person_copy = person.clone

    assert_predicate person_copy, :name_came_from_user?
    refute_predicate person_copy, :age_came_from_user?
  end
end
