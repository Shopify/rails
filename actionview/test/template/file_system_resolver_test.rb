# frozen_string_literal: true

require "abstract_unit"
require "template/resolver_shared_tests"
require "active_support/testing/ractors_assertions"

class FileSystemResolverTest < ActiveSupport::TestCase
  include ResolverSharedTests
  include ActiveSupport::Testing::RactorsAssertions

  def resolver
    ActionView::FileSystemResolver.new(tmpdir)
  end

  DETAILS = { locale: [:en], formats: [:html], variants: [], handlers: [:erb] }.freeze

  def find_all(resolver, name = "hello_world", prefix = "test", partial = false, locals = [])
    resolver.find_all(name, prefix, partial, DETAILS, nil, locals)
  end

  def compile_view
    ActionView::Base.with_empty_template_cache.empty
  end

  def test_freeze_requires_compiled_templates
    ["Hi", "<%# locals: () %>Hi"].each do |source|
      with_file "test/hello_world.html.erb", source
      resolver = ActionView::FileSystemResolver.new(tmpdir)
      resolver.eager_load_templates

      assert_raises(ArgumentError) { resolver.freeze }
    end
  end

  def test_eager_load_templates_populates_cache_without_freezing
    with_file "test/hello_world.html.erb", "Hello!"
    resolver = ActionView::FileSystemResolver.new(tmpdir)
    resolver.eager_load_templates

    assert_not resolver.frozen?
    templates = find_all(resolver)
    assert_equal 1, templates.size
    assert_equal "Hello!", templates[0].source
  end

  def test_eager_loaded_resolver_still_binds_new_locals
    with_file "test/hello_world.html.erb", "<%= message %>"
    resolver = ActionView::FileSystemResolver.new(tmpdir)
    resolver.eager_load_templates

    a = find_all(resolver, "hello_world", "test", false, [:message])[0]
    b = find_all(resolver, "hello_world", "test", false, [:message, :other])[0]

    assert_not_same a, b
    assert_not resolver.frozen?
  end

  def test_freeze_after_eager_load_makes_resolver_shareable
    with_file "test/hello_world.html.erb", "<%# locals: () %>Hi"
    ActiveSupport::Ractors.make_shareable(Mime[:html])
    resolver = ActionView::FileSystemResolver.new(tmpdir)
    resolver.eager_load_templates(compile_view)
    resolver.freeze

    assert_predicate resolver, :frozen?
    assert_ractor_shareable resolver

    templates = find_all(resolver)
    assert_equal 1, templates.size
    assert_predicate templates[0], :frozen?
  end

  def test_freeze_keeps_non_strict_templates_renderable
    with_file "test/_card.html.erb", "<%= post %>"
    view = compile_view
    resolver = ActionView::FileSystemResolver.new(tmpdir)
    resolver.eager_load_templates(view)
    resolver.freeze

    assert_ractor_shareable resolver

    template = find_all(resolver, "card", "test", true, [:post])[0]
    assert_equal "hello", template.render(view, { post: "hello" })
  end

  def test_frozen_non_strict_templates_are_cached_per_locals
    with_file "test/_card.html.erb", "<%= post %>"
    resolver = ActionView::FileSystemResolver.new(tmpdir)
    resolver.eager_load_templates(compile_view)
    resolver.freeze

    a = find_all(resolver, "card", "test", true, [:post])[0]
    b = find_all(resolver, "card", "test", true, [:post])[0]
    c = find_all(resolver, "card", "test", true, [:post, :other])[0]
    d = find_all(resolver, "card", "test", true, [:other, :post])[0]

    assert_same a, b
    assert_not_same a, c
    assert_same c, d
  end

  def test_strict_locals_templates_bind_once_for_any_locals
    with_file "test/hello_world.html.erb", "<%# locals: () %>Hi"
    resolver = ActionView::FileSystemResolver.new(tmpdir)
    key = ActionView::TemplateDetails::Requested.new(**DETAILS)

    a = resolver.find_all("hello_world", "test", false, DETAILS, key, [])[0]
    b = resolver.find_all("hello_world", "test", false, DETAILS, key, [:extra])[0]

    assert_same a, b
    assert_equal [a], resolver.built_templates
  end

  def test_frozen_resolver_returns_empty_for_missing_template
    with_file "test/hello_world.html.erb", "<%# locals: () %>Hi"
    resolver = ActionView::FileSystemResolver.new(tmpdir)
    resolver.eager_load_templates(compile_view)
    resolver.freeze

    assert_empty find_all(resolver, "nonexistent")
  end
end

class FileSystemResolverRactorTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::Isolation
  include ActiveSupport::Testing::RactorsAssertions

  test "bound templates survive their producing Ractor and render with the boot-time container" do
    Dir.mktmpdir do |dir|
      Dir.mkdir(File.join(dir, "test"))
      File.write(File.join(dir, "test", "_card.html.erb"), "<%= post %>")

      Mime.eager_load!
      ActionView::Template::Handlers::ERB.escape_ignore_list.freeze
      ActiveSupport::Ractors.unshareable_proc_action = :raise
      ActiveSupport::Notifications.send(:record_subscriptions)
      ActiveSupport::Ractors.make_shareable(ActiveSupport.event_reporter)

      view_class = ActionView::Base.with_empty_template_cache
      resolver = ActionView::FileSystemResolver.new(dir)
      resolver.eager_load_templates(view_class.empty)
      resolver.freeze

      first, initial = on_ractor(resolver, view_class) do |resolver, view_class|
        details = { locale: [:en], formats: [:html], variants: [], handlers: [:erb] }
        bound = resolver.find_all("card", "test", true, details, nil, [:post]).first
        view = view_class.with_context(ActionView::LookupContext.new([resolver], details))
        [bound, bound.render(view, { post: "hello" })]
      end
      second, subsequent = on_ractor(resolver, view_class) do |resolver, view_class|
        details = { locale: [:en], formats: [:html], variants: [], handlers: [:erb] }
        locals = [+"post"]
        bound = resolver.find_all("card", "test", true, details, nil, locals).first
        locals.first << "_changed"
        view = view_class.with_context(ActionView::LookupContext.new([resolver], details))
        [bound, bound.render(view, { post: "world" })]
      end

      assert_equal ["hello", "world"], [initial, subsequent]
      assert_same first, second
      assert_includes resolver.built_templates, first
    end
  end
end
