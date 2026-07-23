# frozen_string_literal: true

module Arel # :nodoc: all
  module Visitors
    extend ActiveSupport::Autoload

    eager_autoload do
      autoload :Visitor
      autoload :UnsupportedVisitError, "arel/visitors/to_sql"
      autoload :ToSql
      autoload :SQLite, "arel/visitors/sqlite"
      autoload :PostgreSQL, "arel/visitors/postgresql"
      autoload :MySQL, "arel/visitors/mysql"
      autoload :Dot
    end
  end
end
