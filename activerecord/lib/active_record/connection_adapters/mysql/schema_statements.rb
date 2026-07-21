# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module MySQL
      module SchemaStatements # :nodoc:
        # Returns an array of indexes for the given table.
        def indexes(table_name)
          indexes_for_tables([table_name]).each_value.first || []
        end

        def indexes_for_tables(table_names) # :nodoc:
          return {} if table_names.empty?

          optional_columns = +""
          optional_columns << ", EXPRESSION AS 'Expression'" if supports_expression_index?
          if supports_disabling_indexes?
            optional_columns << (mariadb? ? ", IF(ignored = 'NO', 'YES', 'NO') AS 'enabled'" : ", is_visible AS 'enabled'")
          end

          result = query_all(<<~SQL)
            SELECT TABLE_NAME AS 'Table', INDEX_NAME AS 'Key_name',
                   NON_UNIQUE AS 'Non_unique', SEQ_IN_INDEX AS 'Seq_in_index',
                   COLUMN_NAME AS 'Column_name', COLLATION AS 'Collation',
                   SUB_PART AS 'Sub_part', LOWER(INDEX_TYPE) AS 'Index_type',
                   INDEX_COMMENT AS 'Index_comment'#{optional_columns}
            FROM information_schema.statistics
            WHERE (#{statistics_table_scope_sql(table_names)})
              AND index_name != 'PRIMARY'
            ORDER BY table_name, index_name, seq_in_index
          SQL

          indexes_by_table = Hash.new { |h, k| h[k] = [] }

          current_index = nil

          result.each do |row|
            table = row["Table"]
            index_key = [table, row["Key_name"]]

            if current_index != index_key
              current_index = index_key

              mysql_index_type = row["Index_type"].to_sym
              case mysql_index_type
              when :fulltext, :spatial
                index_type = mysql_index_type
              when :btree, :hash
                index_using = mysql_index_type
              end

              index = [
                table,
                row["Key_name"],
                row["Non_unique"].to_i == 0,
                [],
                lengths: {},
                orders: {},
                type: index_type,
                using: index_using,
                comment: row["Index_comment"].presence,
              ]

              if supports_disabling_indexes?
                index[-1][:enabled] = row["enabled"] == "YES"
              end

              indexes_by_table[table] << index
            end

            index = indexes_by_table[table].last

            if expression = row["Expression"]
              expression = expression.gsub("\\'", "'")
              expression = +"(#{expression})" unless expression.start_with?("(")
              index[-2] << expression
              index[-1][:expressions] ||= {}
              index[-1][:expressions][expression] = expression
              index[-1][:orders][expression] = :desc if row["Collation"] == "D"
            else
              index[-2] << row["Column_name"]
              index[-1][:lengths][row["Column_name"]] = row["Sub_part"].to_i if row["Sub_part"]
              index[-1][:orders][row["Column_name"]] = :desc if row["Collation"] == "D"
            end
          end

          indexes_by_table.transform_values! do |table_indexes|
            table_indexes.map! do |index|
              options = index.pop

              if expressions = options.delete(:expressions)
                orders = options.delete(:orders)
                lengths = options.delete(:lengths)

                columns = index[-1].to_h { |name|
                  [ name.to_sym, expressions[name] || +quote_column_name(name) ]
                }

                index[-1] = add_options_for_index_columns(
                  columns, order: orders, length: lengths
                ).values.join(", ")
              end
              MySQL::IndexDefinition.new(*index, **options)
            end
          end

          indexes_by_table
        end

        def create_index_definition(table_name, name, unique, columns, **options)
          MySQL::IndexDefinition.new(table_name, name, unique, columns, **options)
        end

        def add_index_options(table_name, column_name, name: nil, if_not_exists: false, internal: false, **options) # :nodoc:
          index, algorithm, if_not_exists = super
          index.enabled = options[:enabled] unless options[:enabled].nil?
          [index, algorithm, if_not_exists]
        end

        def remove_column(table_name, column_name, type = nil, **options)
          if foreign_key_exists?(table_name, column: column_name)
            remove_foreign_key(table_name, column: column_name)
          end
          algorithm = index_algorithm(options.delete(:algorithm))
          lock = lock_clause(options.delete(:lock))
          return if options[:if_exists] == true && !column_exists?(table_name, column_name)
          sql = +"ALTER TABLE #{quote_table_name(table_name)} #{remove_column_for_alter(table_name, column_name, type, **options)}"
          sql << ", #{algorithm}" if algorithm
          sql << ", #{lock}" if lock
          execute(sql)
        end

        def create_table(table_name, options: default_row_format, **)
          super
        end

        def remove_foreign_key(from_table, to_table = nil, **options)
          # RESTRICT is by default in MySQL.
          options.delete(:on_update) if options[:on_update] == :restrict
          options.delete(:on_delete) if options[:on_delete] == :restrict
          super
        end

        def internal_string_options_for_primary_key
          super.tap do |options|
            if !row_format_dynamic_by_default? && CHARSETS_OF_4BYTES_MAXLEN.include?(charset)
              options[:collation] = collation.sub(/\A[^_]+/, "utf8")
            end
          end
        end

        def update_table_definition(table_name, base)
          MySQL::Table.new(table_name, base)
        end

        def create_schema_dumper(options)
          MySQL::SchemaDumper.create(self, options)
        end

        # Maps logical Rails types to MySQL-specific data types.
        def type_to_sql(type, limit: nil, precision: nil, scale: nil, size: limit_to_size(limit, type), unsigned: nil, **)
          sql =
            case type.to_s
            when "integer"
              integer_to_sql(limit)
            when "text"
              type_with_size_to_sql("text", size)
            when "blob"
              type_with_size_to_sql("blob", size)
            when "binary"
              if (0..0xfff) === limit
                "varbinary(#{limit})"
              else
                type_with_size_to_sql("blob", size)
              end
            else
              super
            end

          sql = "#{sql} unsigned" if unsigned && type != :primary_key
          sql
        end

        def table_alias_length
          256 # https://dev.mysql.com/doc/refman/en/identifiers.html
        end

        def schema_creation # :nodoc:
          MySQL::SchemaCreation.new(self)
        end

        private
          CHARSETS_OF_4BYTES_MAXLEN = ["utf8mb4", "utf16", "utf16le", "utf32"].freeze

          def row_format_dynamic_by_default?
            if mariadb?
              database_version >= "10.2.2"
            else
              database_version >= "5.7.9"
            end
          end

          def default_row_format
            return if row_format_dynamic_by_default?

            unless defined?(@default_row_format)
              if query_value("SELECT @@innodb_file_per_table = 1 AND @@innodb_file_format = 'Barracuda'") == 1
                @default_row_format = "ROW_FORMAT=DYNAMIC"
              else
                @default_row_format = nil
              end
            end

            @default_row_format
          end

          def valid_primary_key_options
            super + [:unsigned, :auto_increment]
          end

          def create_table_definition(name, **options)
            MySQL::TableDefinition.new(self, name, **options)
          end

          def new_column_from_field(table_name, field, _definitions)
            type_metadata = fetch_type_metadata(field["Type"], field["Extra"])
            default, default_function = field["Default"], nil

            if type_metadata.type == :datetime && /\ACURRENT_TIMESTAMP(?:\([0-6]?\))?\z/i.match?(default)
              default = "#{default} ON UPDATE #{default}" if /on update CURRENT_TIMESTAMP/i.match?(field["Extra"])
              default, default_function = nil, default
            elsif type_metadata.extra == "DEFAULT_GENERATED"
              if mariadb?
                default, default_function = nil, default
              else
                default = "(#{default})" unless default.start_with?("(")
                default = default.gsub("\\'", "'")
                default, default_function = nil, default
              end
            elsif type_metadata.type == :text && default&.start_with?("'")
              # strip and unescape quotes
              default = default[1...-1].gsub("\\'", "'")
            end

            MySQL::Column.new(
              field["Field"],
              lookup_cast_type(type_metadata.sql_type),
              default,
              type_metadata,
              field["Null"] == "YES",
              default_function,
              collation: field["Collation"],
              comment: field["Comment"].presence
            )
          end

          def fetch_type_metadata(sql_type, extra = "")
            MySQL::TypeMetadata.new(super(sql_type), extra: extra)
          end

          def extract_foreign_key_action(specifier)
            super unless specifier == "RESTRICT"
          end

          def add_index_length(quoted_columns, **options)
            lengths = options_for_index_columns(options[:length])
            quoted_columns.each do |name, column|
              column << "(#{lengths[name]})" if lengths[name].present?
            end
          end

          def valid_index_options
            index_options = super
            index_options << :enabled if supports_disabling_indexes?
            index_options << :lock
            index_options
          end

          def add_options_for_index_columns(quoted_columns, **options)
            quoted_columns = add_index_length(quoted_columns, **options)
            super
          end

          def data_source_sql(name = nil, type: nil)
            scope = quoted_scope(name, type: type)

            sql = +"SELECT table_name FROM information_schema.tables"
            sql << " WHERE table_schema = #{scope[:schema]}"

            if scope[:name]
              sql << " AND table_name = #{scope[:name]}"
              sql << " AND table_name IN (SELECT table_name FROM information_schema.tables WHERE table_schema = #{scope[:schema]})"
            end

            sql << " AND table_type = #{scope[:type]}" if scope[:type]
            sql
          end

          def quoted_scope(name = nil, type: nil)
            schema, name = extract_schema_qualified_name(name)
            scope = {}
            scope[:schema] = schema ? quote(schema) : "database()"
            scope[:name] = quote(name) if name
            scope[:type] = quote(type) if type
            scope
          end

          def extract_schema_qualified_name(string)
            schema, name = string.to_s.scan(/[^`.\s]+|`[^`]*`/)
            schema, name = nil, schema unless name
            [schema, name]
          end

          def statistics_table_scope_sql(table_names)
            by_schema = table_names.each_with_object(Hash.new { |h, k| h[k] = [] }) do |name, h|
              schema, tbl = extract_schema_qualified_name(name)
              h[schema] << tbl
            end

            by_schema.map do |schema, names|
              schema_sql = schema ? quote(schema) : "database()"
              names_sql = names.map { |n| quote(n) }.join(", ")
              "(table_schema = #{schema_sql} AND table_name IN (#{names_sql}))"
            end.join(" OR ")
          end

          def type_with_size_to_sql(type, size)
            case size&.to_s
            when nil, "tiny", "medium", "long"
              "#{size}#{type}"
            else
              raise ArgumentError,
                "#{size.inspect} is invalid :size value. Only :tiny, :medium, and :long are allowed."
            end
          end

          def limit_to_size(limit, type)
            case type.to_s
            when "text", "blob", "binary"
              case limit
              when 0..0xff;               "tiny"
              when nil, 0x100..0xffff;    nil
              when 0x10000..0xffffff;     "medium"
              when 0x1000000..0xffffffff; "long"
              else raise ArgumentError, "No #{type} type has byte size #{limit}"
              end
            end
          end

          def integer_to_sql(limit)
            case limit
            when 1; "tinyint"
            when 2; "smallint"
            when 3; "mediumint"
            when nil, 4; "int"
            when 5..8; "bigint"
            else raise ArgumentError, "No integer type has byte size #{limit}. Use a decimal with scale 0 instead."
            end
          end
      end
    end
  end
end
