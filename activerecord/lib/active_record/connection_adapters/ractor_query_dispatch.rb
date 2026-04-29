# frozen_string_literal: true

require "ractor/dispatch"

module ActiveRecord
  module ConnectionAdapters
    # Narrow non-main-Ractor → main-Ractor dispatch for AR query execution.
    # Owns the shareability contract: arel and binds are deep-copied via
    # Ractor.make_shareable(_, copy: true) on the calling side; the resulting
    # ActiveRecord::Result is made shareable on the main side before crossing
    # back. The dispatch surface is intentionally limited to select queries
    # (no writes, no transactions, no async, no eager-load).
    module RactorQueryDispatch
      extend self

      # Dispatch a select-style query to the main Ractor. Returns a frozen,
      # shareable ActiveRecord::Result.
      #
      # The closure shipped to the main Ractor must only capture shareable
      # values. We achieve that by:
      #   * deep-copying the arel AST and binds with make_shareable(copy: true)
      #   * passing the model by name (frozen String) and re-resolving via
      #     Object.const_get on the main side
      #   * keeping name/allow_retry as primitive shareable values
      #
      # The result is frozen and made shareable on the main side via
      # Result#make_shareable! before being returned across the boundary.
      def select_all(model, arel, name = nil, binds = [], allow_retry: false)
        shareable_arel  = Ractor.make_shareable(arel,  copy: true)
        shareable_binds = Ractor.make_shareable(binds, copy: true)
        model_name      = model.name
        query_name      = name.nil? ? nil : Ractor.make_shareable(name, copy: true)
        retry_flag      = allow_retry

        Ractor::Dispatch.main.run do
          klass = Object.const_get(model_name)
          result = klass.with_connection do |c|
            c.select_all(shareable_arel, query_name, shareable_binds, async: false, allow_retry: retry_flag)
          end
          result.make_shareable!
        end
      end
    end

    Ractor.make_shareable(RactorQueryDispatch)
  end
end
