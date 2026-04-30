# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module SQLite3
      module Quoting # :nodoc:
        extend ActiveSupport::Concern

        QUOTED_COLUMN_NAMES = Concurrent::Map.new # :nodoc:
        QUOTED_TABLE_NAMES = Concurrent::Map.new # :nodoc:

        module ClassMethods # :nodoc:
          def column_name_matcher
            /
              \A
              (
                (?:
                  # "table_name"."column_name" | function(one or no argument)
                  ((?:\w+\.|"\w+"\.)?(?:\w+|"\w+") | \w+\((?:|\g<2>)\))
                )
                (?:(?:\s+AS)?\s+(?:\w+|"\w+"))?
              )
              (?:\s*,\s*\g<1>)*
              \z
            /ix
          end

          def column_name_with_order_matcher
            /
              \A
              (
                (?:
                  # "table_name"."column_name" | function(one or no argument)
                  ((?:\w+\.|"\w+"\.)?(?:\w+|"\w+") | \w+\((?:|\g<2>)\))
                )
                (?:\s+COLLATE\s+(?:\w+|"\w+"))?
                (?:\s+ASC|\s+DESC)?
              )
              (?:\s*,\s*\g<1>)*
              \z
            /ix
          end

          # +QUOTED_COLUMN_NAMES+ / +QUOTED_TABLE_NAMES+ are
          # +Concurrent::Map+ instances and aren't shareable, so a
          # non-main Ractor that touches the constant raises
          # +Ractor::IsolationError+. Reached e.g. from
          # +Calculations#execute_grouped_calculation+ at
          # calculations.rb:552 via
          # +model.adapter_class.quote_column_name(column_alias)+.
          # Fall back to recomputing the frozen quoted String on
          # non-main; the cache is just a per-input-name memo of a
          # pure function, so skipping it costs an extra +gsub+ per
          # call on the request side. Hot-path (main) keeps the
          # cache untouched.
          def quote_column_name(name)
            if Ractor.main?
              QUOTED_COLUMN_NAMES[name] ||= %Q("#{name.to_s.gsub('"', '""')}").freeze
            else
              %Q("#{name.to_s.gsub('"', '""')}").freeze
            end
          end

          def quote_table_name(name)
            if Ractor.main?
              QUOTED_TABLE_NAMES[name] ||= %Q("#{name.to_s.gsub('"', '""').gsub(".", "\".\"")}").freeze
            else
              %Q("#{name.to_s.gsub('"', '""').gsub(".", "\".\"")}").freeze
            end
          end
        end

        def quote(value) # :nodoc:
          case value
          when Numeric
            if value.finite?
              super
            else
              "'#{value}'"
            end
          else
            super
          end
        end

        def quote_string(s)
          ::SQLite3::Database.quote(s)
        end

        def quote_table_name_for_assignment(table, attr)
          quote_column_name(attr)
        end

        def quoted_time(value)
          value = value.change(year: 2000, month: 1, day: 1)
          quoted_date(value).sub(/\A\d\d\d\d-\d\d-\d\d /, "2000-01-01 ")
        end

        def quoted_binary(value)
          "x'#{value.hex}'"
        end

        def unquoted_true
          1
        end

        def unquoted_false
          0
        end

        def quote_default_expression(value, column) # :nodoc:
          if value.is_a?(Proc)
            value = value.call
            if value.match?(/\A\w+\(.*\)\z/)
              "(#{value})"
            else
              value
            end
          else
            super
          end
        end

        def type_cast(value) # :nodoc:
          case value
          when BigDecimal, Rational
            value.to_f
          when String
            if value.encoding == Encoding::ASCII_8BIT
              super(value.encode(Encoding::UTF_8))
            else
              super
            end
          else
            super
          end
        end
      end
    end
  end
end
