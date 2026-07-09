# frozen_string_literal: true

require "abstract_unit"
require "template/resolver_shared_tests"

class FileSystemResolverTest < ActiveSupport::TestCase
  include ResolverSharedTests

  def resolver
    ActionView::FileSystemResolver.new(tmpdir)
  end

  DETAILS = { locale: [:en], formats: [:html], variants: [], handlers: [:erb] }.freeze

  def find_all(resolver, name = "hello_world", prefix = "test", partial = false, locals = [])
    resolver.find_all(name, prefix, partial, DETAILS, nil, locals)
  end

  def test_eager_load_templates_populates_cache_without_freezing
    with_file "test/hello_world.html.erb", "Hello!"
    r = resolver
    r.eager_load_templates

    assert_not r.frozen?
    templates = find_all(r)
    assert_equal 1, templates.size
    assert_equal "Hello!", templates[0].source
  end

  def test_eager_loaded_resolver_still_binds_new_locals
    with_file "test/hello_world.html.erb", "<%= message %>"
    r = resolver
    r.eager_load_templates

    a = find_all(r, "hello_world", "test", false, [:message])[0]
    b = find_all(r, "hello_world", "test", false, [:message, :other])[0]

    assert_not_same a, b
    assert_not r.frozen?
  end

  def test_freeze_after_eager_load_makes_resolver_shareable
    with_file "test/hello_world.html.erb", "<%# locals: () %>Hi"
    r = resolver
    r.eager_load_templates
    r.freeze

    assert_predicate r, :frozen?
    assert Ractor.shareable?(r)

    templates = find_all(r)
    assert_equal 1, templates.size
    assert_predicate templates[0], :frozen?
  end

  def test_freeze_raises_for_non_strict_partial
    with_file "test/_card.html.erb", "<%= post %>"
    r = resolver
    r.eager_load_templates

    error = assert_raises(ArgumentError) { r.freeze }
    assert_match "test/_card", error.message
    assert_match "strict locals", error.message
  end

  def test_freeze_raises_for_non_strict_template
    with_file "test/hello_world.html.erb", "no locals here"
    r = resolver
    r.eager_load_templates

    error = assert_raises(ArgumentError) { r.freeze }
    assert_match "test/hello_world", error.message
    assert_match "strict locals", error.message
  end

  def test_frozen_resolver_returns_empty_for_missing_template
    with_file "test/hello_world.html.erb", "<%# locals: () %>Hi"
    r = resolver
    r.eager_load_templates
    r.freeze

    assert_empty find_all(r, "nonexistent")
  end
end
