# frozen_string_literal: true

require "active_support/ractors"
require "active_support/dependencies/autoload"

require "active_record/version"

module Arel
  extend ActiveSupport::Autoload

  VERSION = "10.#{ActiveRecord::VERSION::STRING}".freeze

  eager_autoload do
    autoload :ArelError, "arel/errors"
    autoload :EmptyJoinError, "arel/errors"
    autoload :BindError, "arel/errors"

    autoload :Crud
    autoload :FactoryMethods
    autoload :Expressions
    autoload :Predications
    autoload :FilterPredications
    autoload :WindowPredications
    autoload :Math
    autoload :AliasPredication
    autoload :OrderPredications

    autoload :Table
    autoload :Attribute, "arel/attributes/attribute"
    autoload :Attributes
    autoload :Nodes
    autoload :Visitors
    autoload :Collectors

    autoload :TreeManager
    autoload :InsertManager
    autoload :SelectManager
    autoload :UpdateManager
    autoload :DeleteManager
  end

  def self.eager_load!
    super
    Attributes.eager_load!
    Nodes.eager_load!
    Visitors.eager_load!
    Collectors.eager_load!
  end

  # Wrap a known-safe SQL string for passing to query methods, e.g.
  #
  #   Post.order(Arel.sql("REPLACE(title, 'misc', 'zzzz') asc")).pluck(:id)
  #
  # Great caution should be taken to avoid SQL injection vulnerabilities.
  # This method should not be used with unsafe values such as request
  # parameters or model attributes.
  #
  # Take a look at the {security guide}[https://guides.rubyonrails.org/security.html#sql-injection]
  # for more information.
  #
  # To construct a more complex query fragment, including the possible
  # use of user-provided values, the +sql_string+ may contain <tt>?</tt> and
  # +:key+ placeholders, corresponding to the additional arguments. Note
  # that this behavior only applies when bind value parameters are
  # supplied in the call; without them, the placeholder tokens have no
  # special meaning, and will be passed through to the query as-is.
  #
  # The +:retryable+ option can be used to mark the SQL as safe to retry.
  # Use this option only if the SQL is idempotent, as it could be executed
  # more than once.
  def self.sql(sql_string, *positional_binds, retryable: false, **named_binds)
    if Arel::Nodes::SqlLiteral === sql_string
      sql_string
    elsif positional_binds.empty? && named_binds.empty?
      Arel::Nodes::SqlLiteral.new(sql_string, retryable: retryable)
    else
      Arel::Nodes::BoundSqlLiteral.new sql_string, positional_binds, named_binds
    end
  end

  def self.star # :nodoc:
    sql("*", retryable: true)
  end

  def self.arel_node?(value) # :nodoc:
    value.is_a?(Arel::Nodes::Node) || value.is_a?(Arel::Attribute) || value.is_a?(Arel::Nodes::SqlLiteral)
  end

  def self.fetch_attribute(value, &block) # :nodoc:
    unless String === value
      value.fetch_attribute(&block)
    end
  end
end
