# frozen_string_literal: true

require "active_model/attribute"

module Arel # :nodoc: all
  module Nodes
    extend ActiveSupport::Autoload

    eager_autoload do
      # node
      autoload :Node
      autoload :NodeExpression
      autoload :SelectStatement
      autoload :SelectCore
      autoload :InsertStatement
      autoload :UpdateStatement
      autoload :DeleteStatement
      autoload :BindParam
      autoload :Fragments

      # terminal
      autoload :Distinct, "arel/nodes/terminal"
      autoload :True
      autoload :False

      # unary
      require "arel/nodes/unary"
      autoload :Grouping
      autoload :HomogeneousIn
      require "arel/nodes/ordering"
      autoload :Ascending
      autoload :Descending
      autoload :UnqualifiedColumn
      require "arel/nodes/with"

      # binary
      require "arel/nodes/binary"
      require "arel/nodes/equality"
      autoload :Filter
      autoload :In
      autoload :JoinSource
      autoload :TableAlias
      require "arel/nodes/infix_operation"
      require "arel/nodes/unary_operation"
      autoload :Over
      require "arel/nodes/matches"
      require "arel/nodes/regexp"
      autoload :Cte

      # nary (And and Or)
      require "arel/nodes/nary"

      # function
      require "arel/nodes/function"
      autoload :Count
      autoload :Extract
      autoload :ValuesList
      autoload :NamedFunction

      # windows
      require "arel/nodes/window"

      # conditional expressions
      require "arel/nodes/case"

      # joins
      autoload :FullOuterJoin
      autoload :InnerJoin
      autoload :OuterJoin
      autoload :RightOuterJoin
      autoload :StringJoin
      autoload :LeadingJoin

      autoload :Comment

      autoload :SqlLiteral
      autoload :BoundSqlLiteral

      require "arel/nodes/casted"
    end

    # Quote and wrap a value in the appropriate Arel node. When +other+ is
    # already an Arel node, an attribute, a table, a select manager, an SQL
    # literal, or an ActiveModel::Attribute, it is returned unchanged.
    # Otherwise it is wrapped in either a Nodes::Casted (when an attribute
    # is given to cast against) or a Nodes::Quoted.
    #
    # This is a module method on Arel::Nodes so it is defined here in the
    # autoload hub rather than in an autoloaded file: autoload only triggers
    # on constant references, so a module method defined in +casted.rb+ would
    # not be available until Nodes::Casted or Nodes::Quoted was referenced.
    def self.build_quoted(other, attribute = nil)
      case other
      when Arel::Nodes::Node, Arel::Attributes::Attribute, Arel::Table, Arel::SelectManager, Arel::Nodes::SqlLiteral, ActiveModel::Attribute
        other
      else
        case attribute
        when Arel::Attributes::Attribute
          Casted.new other, attribute
        else
          Quoted.new other
        end
      end
    end
  end
end
