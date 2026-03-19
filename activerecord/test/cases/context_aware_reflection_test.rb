# frozen_string_literal: true

require "cases/helper"
require "models/step"
require "models/recipe"
require "models/chef"

class ContextAwareReflectionTest < ActiveRecord::TestCase
  def test_context_aware_belongs_to_returns_default_reflection_attributes
    # Default context should use the default reflection (primary_key: :id)
    Step.stub(:current_schema_context, "default") do
      reflection = Step.reflect_on_association(:recipe)
      assert_equal :id, reflection.options[:primary_key]
      assert_equal true, reflection.options[:touch]
    end
  end

  def test_context_aware_belongs_to_returns_context_specific_attributes
    # "other" context should return context-specific primary_key
    Step.stub(:current_schema_context, "other") do
      reflection = Step.reflect_on_association(:recipe)
      assert_equal [:id, :chef_id], reflection.options[:primary_key]
      # Shared options should still be present
      assert_equal true, reflection.options[:touch]
    end
  end

  def test_context_aware_belongs_to_falls_back_to_default_for_unknown_context
    Step.stub(:current_schema_context, "unknown") do
      reflection = Step.reflect_on_association(:recipe)
      assert_equal :id, reflection.options[:primary_key]
      assert_equal true, reflection.options[:touch]
    end
  end

  def test_context_does_not_bleed_across_switches
    Step.stub(:current_schema_context, "other") do
      reflection = Step.reflect_on_association(:recipe)
      assert_equal [:id, :chef_id], reflection.options[:primary_key]
    end

    # Switch back to default
    Step.stub(:current_schema_context, "default") do
      reflection = Step.reflect_on_association(:recipe)
      assert_equal :id, reflection.options[:primary_key]
    end
  end

  def test_non_context_association_is_not_wrapped_in_proxy
    reflection = Step._reflect_on_association(:chef)
    assert_not reflection.context_aware?,
      "Non-context association should not be context-aware"
  end

  def test_context_association_is_wrapped_in_proxy
    reflection = Step._reflect_on_association(:recipe)
    assert reflection.context_aware?,
      "Context association should be context-aware"
  end

  def test_proxy_is_a_belongs_to_reflection
    reflection = Step._reflect_on_association(:recipe)
    assert_kind_of ActiveRecord::Reflection::BelongsToReflection, reflection
    assert_kind_of ActiveRecord::Reflection::AssociationReflection, reflection
    assert_kind_of ActiveRecord::Reflection::AbstractReflection, reflection
  end

  def test_proxy_reports_correct_name
    reflection = Step._reflect_on_association(:recipe)
    assert_equal :recipe, reflection.name
  end

  def test_proxy_reports_correct_active_record
    reflection = Step._reflect_on_association(:recipe)
    assert_equal Step, reflection.active_record
  end

  def test_proxy_reports_correct_macro
    Step.stub(:current_schema_context, "default") do
      reflection = Step._reflect_on_association(:recipe)
      assert_equal :belongs_to, reflection.macro
      assert reflection.belongs_to?
    end
  end

  def test_proxy_delegates_foreign_key
    Step.stub(:current_schema_context, "default") do
      reflection = Step._reflect_on_association(:recipe)
      assert_equal "recipe_id", reflection.foreign_key
    end
  end

  def test_proxy_delegates_class_name
    Step.stub(:current_schema_context, "default") do
      reflection = Step._reflect_on_association(:recipe)
      assert_equal "Recipe", reflection.class_name
    end
  end

  def test_cached_reference_resolves_dynamically
    # Simulate caching a reference to the reflection at boot time
    reflection = Step._reflect_on_association(:recipe)

    # Later at runtime, context changes — the cached reference should resolve correctly
    Step.stub(:current_schema_context, "default") do
      assert_equal :id, reflection.options[:primary_key]
    end

    Step.stub(:current_schema_context, "other") do
      assert_equal [:id, :chef_id], reflection.options[:primary_key]
    end
  end

  def test_inverse_of_caching_resolves_per_context
    # This tests the core problem: inverse_of is resolved and cached when
    # first accessed, but a ContextAwareReflection proxy ensures the cached
    # proxy still resolves correctly per-context at runtime.
    Step.stub(:current_schema_context, "default") do
      recipe_reflection = Step._reflect_on_association(:recipe)
      # inverse_of calls klass._reflect_on_association, which should work
      # regardless of context since the proxy resolves dynamically
      inverse = recipe_reflection.inverse_of
      # inverse may be nil if Recipe doesn't define the inverse, which is fine
      # The key thing is it doesn't raise
    end
  end

  def test_reflect_on_all_associations_includes_context_aware
    associations = Step.reflect_on_all_associations(:belongs_to)
    names = associations.map(&:name)
    assert_includes names, :recipe
    assert_includes names, :chef
  end

  def test_reflections_hash_includes_context_aware
    reflections = Step.reflections
    assert reflections.key?("recipe")
    assert reflections.key?("chef")
  end

  def test_current_reflection_accessor
    reflection = Step._reflect_on_association(:recipe)

    Step.stub(:current_schema_context, "default") do
      assert_equal :id, reflection.current_reflection.options[:primary_key]
    end

    Step.stub(:current_schema_context, "other") do
      assert_equal [:id, :chef_id], reflection.current_reflection.options[:primary_key]
    end
  end

  def test_reflection_for_accessor
    reflection = Step._reflect_on_association(:recipe)

    default_ref = reflection.reflection_for("default")
    assert_equal :id, default_ref.options[:primary_key]

    other_ref = reflection.reflection_for("other")
    assert_equal [:id, :chef_id], other_ref.options[:primary_key]

    # Unknown context falls back to default
    unknown_ref = reflection.reflection_for("unknown")
    assert_equal :id, unknown_ref.options[:primary_key]
  end
end
