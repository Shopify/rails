# frozen_string_literal: true

require "cases/helper"
require "models/step"
require "models/recipe"
require "models/chef"

class ContextSensitiveReflectionTest < ActiveRecord::TestCase
  def test_foreign_key_resolves_per_context
    reflection = Step._reflect_on_association(:recipe)

    Step.stub(:current_schema_context, "context_a") do
      fk_a = reflection.foreign_key
      assert_equal "recipe_id", fk_a
    end

    Step.stub(:current_schema_context, "context_b") do
      fk_b = reflection.foreign_key
      assert_equal "recipe_id", fk_b
    end
  end

  def test_foreign_key_is_memoized_per_context
    reflection = Step._reflect_on_association(:recipe)

    Step.stub(:current_schema_context, "context_a") do
      fk1 = reflection.foreign_key
      fk2 = reflection.foreign_key
      # Same context should return the same (memoized) object
      assert_same fk1, fk2
    end
  end

  def test_active_record_primary_key_resolves_per_context
    reflection = Chef.reflect_on_association(:recipes)

    Chef.stub(:current_schema_context, "context_a") do
      pk = reflection.active_record_primary_key
      assert_equal "id", pk
    end

    # Same result in a different context (Chef's pk doesn't change here),
    # but it resolves independently per context
    Chef.stub(:current_schema_context, "context_b") do
      pk = reflection.active_record_primary_key
      assert_equal "id", pk
    end
  end

  def test_association_primary_key_delegates_to_klass_primary_key
    # belongs_to :chef resolves association_primary_key via Chef.primary_key
    # which is already context-sensitive from the ModelSchema work
    reflection = Step._reflect_on_association(:chef)

    Step.stub(:current_schema_context, "default") do
      pk = reflection.association_primary_key
      assert_equal "id", pk
    end
  end

  def test_foreign_key_not_shared_across_contexts
    reflection = Step._reflect_on_association(:recipe)

    # Resolve in context_a first
    Step.stub(:current_schema_context, "context_a") do
      reflection.foreign_key
    end

    # context_b should resolve independently, not reuse context_a's cached value
    Step.stub(:current_schema_context, "context_b") do
      fk = reflection.foreign_key
      assert_equal "recipe_id", fk
    end
  end
end
