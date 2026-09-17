# frozen_string_literal: true

require "cases/helper"
require "active_support/core_ext/object/with"
require "models/company"
require "models/member"
require "models/sponsor"
require "models/author"
require "models/person"
require "models/comment"
require "models/item"
require "models/tagging"
require "models/tag"
require "models/post"
require "models/ship"
require "models/cpk"
require "models/book"
require "models/hardback"

class AssociationRouteTest < ActiveRecord::TestCase
  fixtures :items, :posts, :taggings

  class ThroughAutosaveDestination < ActiveRecord::Base
    self.table_name = "companies"
    self.inheritance_column = nil
    self.primary_key = :firm_id
  end

  class SelfRoutedCompany < ActiveRecord::Base
    self.table_name = "companies"
    self.inheritance_column = nil

    belongs_to :parent, class_name: name, foreign_key: :firm_id, optional: true
    belongs_to :mentor, class_name: name, foreign_key: :client_of, optional: true
    has_one :parents_mentor, through: :parent, source: :mentor
    has_one :scoped_parents_mentor, ->(owner) { where.not(name: owner.name) }, through: :parent, source: :mentor
    has_one :mentors_parent, through: :mentor, source: :parent
    has_one :parents_mentors_parent, through: :parent, source: :mentors_parent
  end

  class NullableRoutePost < ActiveRecord::Base
    self.table_name = "posts"
    self.inheritance_column = nil
    serialize :type, coder: YAML, type: Hash

    has_many :nullable_route_comments,
      class_name: "AssociationRouteTest::NullableRouteComment",
      foreign_key: :post_id
  end

  class NullableRouteComment < ActiveRecord::Base
    self.table_name = "comments"
    self.inheritance_column = nil
    serialize :type, coder: YAML, type: Hash
  end

  class SingletonRoutePost < NullableRoutePost
    self.primary_key = [:id]
  end

  class SingletonRouteComment < NullableRouteComment
    belongs_to :scalar_reference,
      class_name: "AssociationRouteTest::SingletonRoutePost",
      foreign_key: :post_id,
      primary_key: [:id],
      optional: true
    belongs_to :composite_reference,
      class_name: "AssociationRouteTest::NullableRoutePost",
      foreign_key: [:post_id],
      primary_key: :id,
      optional: true
    belongs_to :composite_reference_and_target,
      class_name: "AssociationRouteTest::SingletonRoutePost",
      foreign_key: [:post_id],
      primary_key: [:id],
      optional: true
  end

  class DoubleAliasedRouteComment < NullableRouteComment
    alias_attribute :route_fk, :post_id
    alias_attribute :post_id, :author_id

    belongs_to :routed_post, class_name: "Post", foreign_key: :route_fk, optional: true
  end

  class DoubleAliasedTypeRouteComment < NullableRouteComment
    alias_attribute :routed_type, :author_type
    alias_attribute :author_type, :person_type
  end

  class AliasedCompositeRouteBook < Cpk::Book
    alias_attribute :route_author_id, :author_id
    alias_attribute :route_book_id, :id
  end

  class AliasedCompositeRouteReview < ActiveRecord::Base
    self.table_name = "cpk_reviews"
    alias_attribute :route_author_id, :author_id
    alias_attribute :route_book_id, :number

    belongs_to :routed_book,
      class_name: "AssociationRouteTest::AliasedCompositeRouteBook",
      primary_key: [:route_author_id, :route_book_id],
      foreign_key: [:route_author_id, :route_book_id],
      optional: true
  end

  class AliasedAsyncRoutePost < ActiveRecord::Base
    self.table_name = "posts"
    alias_attribute :route_key, :author_id
  end

  class RemappedAsyncRoutePost < AliasedAsyncRoutePost
    alias_attribute :route_key, :id
  end

  class AliasedAsyncRouteComment < NullableRouteComment
    belongs_to :routed_post,
      class_name: "AssociationRouteTest::AliasedAsyncRoutePost",
      primary_key: :route_key,
      foreign_key: :post_id,
      optional: true
  end

  class RoutedItem < Item
    has_one :routed_item,
      through: :tagging,
      source: :taggable,
      source_type: "Item"
  end

  class InverseAliasedRouteComment < ActiveRecord::Base
    self.table_name = "comments"
    self.inheritance_column = nil

    alias_attribute :route_fk, :post_id
  end

  class InverseRemappedRouteComment < InverseAliasedRouteComment
    alias_attribute :route_fk, :author_id
  end

  class ConstrainedRouteMember < ActiveRecord::Base
    self.table_name = "members"

    has_one :routed_sponsor,
      -> { order(:id) },
      as: :sponsorable,
      class_name: "Sponsor"
  end

  class ConstrainedRoutePost < ActiveRecord::Base
    self.table_name = "posts"
    self.inheritance_column = nil

    has_many :route_links,
      class_name: "AssociationRouteTest::ConstrainedRouteLink",
      foreign_key: :sponsorable_id
    has_many :route_ships, through: :route_links, source: :ship
  end

  class StringKeyRouteShip < Ship
    attribute :pirate_id, :string
  end

  class ConstrainedRouteLink < ActiveRecord::Base
    self.table_name = "sponsors"

    belongs_to :ship,
      class_name: "Ship",
      foreign_key: :club_id,
      primary_key: :pirate_id,
      optional: true
  end

  class AliasedThroughRouteLink < ActiveRecord::Base
    self.table_name = "sponsors"

    alias_attribute :route_fk, :club_id
    belongs_to :ship,
      class_name: "Ship",
      foreign_key: :route_fk,
      primary_key: :pirate_id,
      optional: true
  end

  class RemappedThroughRouteLink < AliasedThroughRouteLink
    alias_attribute :route_fk, :sponsor_id
  end

  class AliasedThroughRoutePost < ActiveRecord::Base
    self.table_name = "posts"
    self.inheritance_column = nil

    has_many :aliased_route_links,
      class_name: "AssociationRouteTest::RemappedThroughRouteLink",
      foreign_key: :sponsorable_id
    has_many :aliased_route_ships,
      through: :aliased_route_links,
      source: :ship
  end

  class InverseThroughRouteComment < ActiveRecord::Base
    self.table_name = "comments"
    self.inheritance_column = nil

    alias_attribute :route_fk, :post_id
    alias_attribute :route_type, :author_type
  end

  class InverseThroughRoutePost < ActiveRecord::Base
    self.table_name = "posts"
    self.inheritance_column = nil

    alias_attribute :route_fk, :author_id
    alias_attribute :route_type, :type
    has_many :inverse_route_comments,
      class_name: "AssociationRouteTest::InverseThroughRouteComment",
      foreign_key: :route_fk
    has_many :polymorphic_route_comments,
      as: :commentable,
      class_name: "AssociationRouteTest::InverseThroughRouteComment",
      foreign_key: :route_fk,
      foreign_type: :route_type
  end

  class InverseThroughRouteAuthor < ActiveRecord::Base
    self.table_name = "authors"

    has_many :inverse_route_posts,
      class_name: "AssociationRouteTest::InverseThroughRoutePost",
      foreign_key: :author_id
    has_many :inverse_route_comments,
      through: :inverse_route_posts,
      source: :inverse_route_comments
    has_many :polymorphic_route_comments,
      through: :inverse_route_posts,
      source: :polymorphic_route_comments
  end

  class BooleanRouteBook < ActiveRecord::Base
    self.table_name = "books"

    has_many :boolean_route_comments,
      class_name: "Comment",
      foreign_key: :author_type,
      primary_key: :boolean_status
  end

  class TouchRouteBook < ActiveRecord::Base
    self.table_name = "books"

    default_scope { where(name: "Touch route target") }
  end

  class SingletonTouchRouteReference < ActiveRecord::Base
    self.table_name = "books"

    belongs_to :routed_book,
      class_name: "AssociationRouteTest::TouchRouteBook",
      foreign_key: [:boolean_status],
      primary_key: [:boolean_status],
      touch: true,
      optional: true
  end

  class ArrayRouteRecord < ActiveRecord::Base
    self.table_name = "bigint_array"

    belongs_to :same_row,
      class_name: "AssociationRouteTest::ArrayRouteRecord",
      foreign_key: :id,
      optional: true
    belongs_to :same_array,
      class_name: "AssociationRouteTest::ArrayRouteRecord",
      foreign_key: [:big_int_data_points],
      primary_key: [:big_int_data_points],
      optional: true
  end

  def test_association_link_combines_constraints_with_the_reference
    reference = build_mapping(reference_key: :post_id, target_key: :id)
    constraints = build_mapping(reference_key: :account_id, target_key: :account_id)
    link = ActiveRecord::AssociationLink.new(reference: reference, constraints: constraints)

    assert_equal [["post_id", "id"]], link.reference.to_a
    assert_equal [["account_id", "account_id"]], link.constraints.to_a
    assert_equal [
      ["account_id", "account_id"],
      ["post_id", "id"],
    ], link.match.to_a
  end

  def test_unconstrained_links_reuse_the_reference_and_empty_mapping
    empty = ActiveRecord::Key::Mapping.empty
    reference = build_mapping(reference_key: :post_id, target_key: :id)

    2.times do
      link = ActiveRecord::AssociationLink.new(reference: reference)

      assert_same empty, link.constraints
      assert_same reference, link.match
    end
  end

  def test_links_normalize_match_keys_without_changing_reference_shape
    [[:post_id, [:id]], [[:post_id], :id], [[:post_id], [:id]]].each do |reference_key, target_key|
      reference = build_mapping(reference_key: reference_key, target_key: target_key)
      link = ActiveRecord::AssociationLink.new(reference: reference)
      route = ActiveRecord::AssociationRoute.new(link: link)

      assert_same reference, link.reference
      assert_same reference.reference_key, route.reference_origin_key
      assert_same reference.target_key, route.reference_destination_key
      assert_equal "post_id", route.origin_key.name
      assert_equal "id", route.destination_key.name
      assert_equal [["post_id", "id"]], link.match.to_a
    end
  end

  def test_unconstrained_routes_share_frozen_match_and_reference_pairs
    keys = [
      [:post_id, :id],
      [[:post_id], :id],
      [:post_id, [:id]],
      [[:post_id], [:id]],
      [[:tenant_id, :post_id], [:tenant_id, :id]],
      [nil, nil],
      [[], []],
      [nil, []],
      [[], nil],
    ]

    keys.each do |reference_name, target_name|
      reference = build_mapping(reference_key: reference_name, target_key: target_name)
      link = ActiveRecord::AssociationLink.new(reference: reference)
      [ActiveRecord::AssociationRoute, ActiveRecord::AssociationRoute::Reverse].each do |route_class|
        route = route_class.new(link: link)
        expected = reference.to_a
        expected = expected.map(&:reverse) if route_class == ActiveRecord::AssociationRoute::Reverse
        matches = route.each_match { }
        references = route.each_reference { }

        assert_equal expected, matches
        assert_same matches, references
        assert_predicate matches, :frozen?
        assert(matches.all?(&:frozen?))
        assert_same reference.reference_key, route.link.reference.reference_key
        assert_same reference.target_key, route.link.reference.target_key
      end
    end
  end

  def test_constrained_routes_keep_match_and_reference_pairs_distinct
    link = ActiveRecord::AssociationLink.new(
      reference: build_mapping(reference_key: :post_id, target_key: :id),
      constraints: build_mapping(reference_key: :blog_id, target_key: :tenant_id)
    )

    [ActiveRecord::AssociationRoute, ActiveRecord::AssociationRoute::Reverse].each do |route_class|
      route = route_class.new(link: link)
      expected_match = [["blog_id", "tenant_id"], ["post_id", "id"]]
      expected_reference = [["post_id", "id"]]
      if route_class == ActiveRecord::AssociationRoute::Reverse
        expected_match.map!(&:reverse)
        expected_reference.map!(&:reverse)
      end
      matches = route.each_match { }
      references = route.each_reference { }

      assert_equal expected_match, matches
      assert_equal expected_reference, references
      assert_not_same matches, references
      assert_predicate matches, :frozen?
      assert_predicate references, :frozen?
      assert(matches.all?(&:frozen?))
      assert(references.all?(&:frozen?))
    end
  end

  def test_unconstrained_routes_share_empty_constraint_pairs
    link = ActiveRecord::AssociationLink.new(reference: build_mapping(reference_key: :post_id, target_key: :id))
    forward = ActiveRecord::AssociationRoute.new(link: link)
    inverse = ActiveRecord::AssociationRoute::Reverse.new(link: link)

    pairs = forward.each_constraint { flunk "Yielded an empty constraint" }
    assert_empty pairs
    assert_same pairs, inverse.each_constraint { flunk "Yielded an empty constraint" }
    assert_predicate pairs, :frozen?
  end

  def test_belongs_to_route_is_physically_oriented_from_foreign_key
    reflection = Client.reflect_on_association(:firm)
    route = reflection.association_route

    assert_equal [["client_of", "id"]], route.link.reference.to_a
    assert_equal "client_of", route.origin_key.name
    assert_equal "id", route.destination_key.name
  end

  def test_has_many_route_preserves_physical_orientation_and_reverses_traversal
    reflection = Firm.reflect_on_association(:clients_of_firm)
    route = reflection.association_route

    assert_equal [["client_of", "id"]], route.link.reference.to_a
    assert_equal "id", route.origin_key.name
    assert_equal "client_of", route.destination_key.name
  end

  def test_default_non_polymorphic_routes_are_shared_with_explicit_declared_endpoints
    reflections = [
      Client.reflect_on_association(:firm),
      Firm.reflect_on_association(:clients_of_firm),
    ]

    reflections.each do |reflection|
      route = reflection.association_route
      assert_not_respond_to reflection, :association_route_for_origin
      assert_not_respond_to reflection, :association_route_for_target

      reflection.stub(:association_route_constraints, ->(*) { flunk "Rebuilt cached route constraints" }) do
        assert_same route, reflection.association_route(origin_class: reflection.active_record, destination_class: reflection.klass)
      end

      reflection.stub(:klass, -> { flunk "Resolved a cached route's destination again" }) do
        assert_same route, reflection.association_route
      end
    end
  end

  def test_variant_route_resolution_is_cached_by_endpoint_classes
    variants = [
      [Client.reflect_on_association(:firm), SpecialClient, Firm],
      [Member.reflect_on_association(:sponsor), Member, Sponsor],
      [Sponsor.reflect_on_association(:sponsorable), Sponsor, Member],
    ]

    variants.each do |reflection, origin_class, destination_class|
      route = reflection.association_route(origin_class: origin_class, destination_class: destination_class)

      reflection.stub(:association_route_constraints, ->(*) { flunk "Rebuilt cached route constraints" }) do
        assert_same route, reflection.association_route(origin_class: origin_class, destination_class: destination_class)
      end
    end
  end

  def test_cached_inverse_polymorphic_route_does_not_resolve_the_destination_again
    reflection = Member.reflect_on_association(:sponsor)
    route = reflection.association_route

    reflection.stub(:klass, -> { flunk "Resolved a cached route's destination again" }) do
      assert_same route, reflection.association_route
    end
  end

  def test_clearing_route_caches_discards_resolved_and_interned_routes
    reflection = Member.reflect_on_association(:sponsor)
    route = reflection.association_route

    reflection.clear_association_scope_cache
    rebuilt_route = reflection.association_route

    assert_not_same route, rebuilt_route
    assert_equal route.link.reference, rebuilt_route.link.reference
    assert_equal route.fixed_reference_values, rebuilt_route.fixed_reference_values
  ensure
    reflection&.clear_association_scope_cache
  end

  def test_polymorphic_route_caches_can_be_cleared_with_a_concrete_destination
    reflection = Sponsor.reflect_on_association(:sponsorable)
    route = reflection.association_route(destination_class: Member)

    reflection.clear_association_scope_cache(Member)
    rebuilt_route = reflection.association_route(destination_class: Member)

    assert_not_same route, rebuilt_route
    assert_equal route.link.reference, rebuilt_route.link.reference
    assert_equal route.fixed_reference_values, rebuilt_route.fixed_reference_values
  ensure
    reflection&.clear_association_scope_cache(Member)
  end

  def test_frozen_reflections_can_resolve_and_clear_route_caches
    [false, true].each do |warm|
      fresh_route_reflections.each do |reflection, destination_class|
        previous = reflection.association_route(destination_class: destination_class) if warm
        reflection.freeze
        route = reflection.association_route(destination_class: destination_class)

        assert_same previous, route if warm
        assert_same route, reflection.association_route(destination_class: destination_class)

        reflection.clear_association_scope_cache(destination_class)
        assert_not_same route, reflection.association_route(destination_class: destination_class)
      end
    end
  end

  def test_frozen_polymorphic_reflection_clears_unbound_and_concrete_routes
    reflection, destination_class = fresh_route_reflections.last
    reflection.freeze
    unbound = reflection.association_route
    concrete = reflection.association_route(destination_class: destination_class)

    reflection.clear_association_scope_cache(destination_class)

    assert_not_same unbound, reflection.association_route
    assert_not_same concrete, reflection.association_route(destination_class: destination_class)
  end

  def test_copied_reflections_have_independent_route_caches
    fresh_route_reflections.each do |reflection, destination_class|
      original = reflection.association_route(destination_class: destination_class)
      copy = reflection.dup
      copied = copy.association_route(destination_class: destination_class)

      assert_not_same original, copied
      assert_equal original.each_match.to_a, copied.each_match.to_a
      copy.clear_association_scope_cache(destination_class)
      assert_not_same copied, copy.association_route(destination_class: destination_class)
      assert_same original, reflection.association_route(destination_class: destination_class)
    end
  end

  def test_copies_of_frozen_reflections_have_independent_route_caches
    fresh_route_reflections.each do |reflection, destination_class|
      reflection.freeze
      original = reflection.association_route(destination_class: destination_class)

      [reflection.dup, reflection.clone, reflection.clone(freeze: false)].each do |copy|
        copied = copy.association_route(destination_class: destination_class)

        assert_not_same original, copied
        assert_equal original.each_match.to_a, copied.each_match.to_a
        copy.freeze
        assert_same copied, copy.association_route(destination_class: destination_class)
        copy.clear_association_scope_cache(destination_class)
        assert_not_same copied, copy.association_route(destination_class: destination_class)
        assert_same original, reflection.association_route(destination_class: destination_class)
      end
    end
  end

  if RUBY_VERSION >= "4.0"
    def test_route_caches_do_not_prevent_reflection_sharing_and_are_ractor_local
      [false, true].each do |warm|
        fresh_route_reflections.each do |reflection, destination_class|
          destination_class.initialize_find_by_cache
          original = reflection.association_route(destination_class: destination_class) if warm
          ActiveSupport::Ractors.make_shareable(reflection)
          original ||= reflection.association_route(destination_class: destination_class)

          reused, cleared, pairs = Ractor.new(reflection, destination_class) do |reflection, destination_class|
            route = reflection.association_route(destination_class: destination_class)
            same_route = route.equal?(reflection.association_route(destination_class: destination_class))
            reflection.clear_association_scope_cache(destination_class)
            new_route = !route.equal?(reflection.association_route(destination_class: destination_class))
            [same_route, new_route, route.each_match.to_a]
          end.value

          assert reused
          assert cleared
          assert_equal original.each_match.to_a, pairs
          assert_same original, reflection.association_route(destination_class: destination_class)
        end
      end
    end

    def test_equivalent_polymorphic_routes_are_interned_in_another_ractor
      reflection, = fresh_route_reflections.last
      Company.primary_key
      Firm.primary_key
      ActiveSupport::Ractors.make_shareable(reflection)

      shared = Ractor.new(reflection) do |reflection|
        company_route = reflection.association_route(destination_class: Company)
        firm_route = reflection.association_route(destination_class: Firm)
        company_route.equal?(firm_route)
      end.value

      assert shared
    end

    def test_match_normalizers_can_be_built_in_another_ractor
      model = Class.new(ActiveRecord::Base) do
        self.table_name = "companies"
        def self.name = "RactorRouteModel"
      end
      ActiveSupport::Ractors.with(unshareable_proc_action: :raise) do
        model.load_schema
      end
      route = build_belongs_to_route(
        reference: { reference_key: :name, target_key: :id },
        constraints: { reference_key: nil, target_key: nil }
      )

      values = Ractor.new(route, model) do |route, model|
        origin, destination = route.match_normalizers(origin_class: model, destination_class: model)
        [origin.first.call(123), destination.first.call(456), origin.first.call(nil), destination.first.call(false)]
      end.value

      assert_equal ["123", "456", nil, "false"], values
    end
  end

  def test_equivalent_inverse_polymorphic_routes_share_identity
    reflection = Member.reflect_on_association(:sponsor)
    origin_class = Class.new(Member) do
      def self.name = "EquivalentRouteMember"
    end
    variant = reflection.association_route(origin_class: origin_class)

    assert_same variant, reflection.association_route
  end

  def test_inverse_polymorphic_route_cache_can_be_invalidated_after_metadata_changes
    reflection = ConstrainedRouteMember.reflect_on_association(:routed_sponsor)
    full = ActiveRecord::Base.with(store_full_class_name: true) do
      reflection.clear_association_scope_cache
      reflection.association_route
    end
    short = ActiveRecord::Base.with(store_full_class_name: false) do
      reflection.clear_association_scope_cache
      reflection.association_route(origin_class: ConstrainedRouteMember, destination_class: Sponsor)
    end

    assert_equal({ "sponsorable_type" => ConstrainedRouteMember.name }, full.fixed_reference_values)
    assert_equal({ "sponsorable_type" => "ConstrainedRouteMember" }, short.fixed_reference_values)
    assert_not_same full, short
  ensure
    reflection&.clear_association_scope_cache
  end

  def test_inverse_route_constraints_receive_the_oriented_endpoint_classes
    reflection = Member.reflect_on_association(:sponsor)
    origin_class = Class.new(Member) do
      def self.name = "ConcreteRouteMember"
    end
    destination_class = Class.new(Sponsor) do
      def self.name = "ConcreteRouteSponsor"
    end
    constraints_for = lambda do |reference_class, target_class|
      assert_same destination_class, reference_class
      assert_same origin_class, target_class
      ActiveRecord::Key::Mapping.empty
    end

    reflection.stub(:association_route_constraints, constraints_for) do
      reflection.association_route(origin_class: origin_class, destination_class: destination_class)
    end
  end

  def test_polymorphic_route_writes_nil_without_a_destination_class
    reflection = Sponsor.reflect_on_association(:sponsorable)
    reference = Sponsor.new(sponsorable_id: 42, sponsorable_type: "MissingClass")

    reflection.stub(:klass, -> { flunk "Tried to infer a polymorphic destination" }) do
      route = reflection.association_route
      assert_same route, reflection.association_route
      assert_equal "sponsorable_id", route.reference_origin_key.name
      assert_equal({ "sponsorable_id" => nil }, route.link.reference_values(nil))

      route.write(reference, nil)
      assert_nil reference.sponsorable_id
      assert_nil reference.sponsorable_type

      bound_route = reflection.association_route(destination_class: Member)
      assert_equal [["sponsorable_id", "id"]], bound_route.link.reference.to_a
      bound_route.write(reference, Member.new)
      assert_nil reference.sponsorable_id
      assert_equal Member.polymorphic_name, reference.sponsorable_type
    end
  end

  def test_runtime_reflection_keeps_its_resolved_join_route
    association = Client.new.association(:firm)
    route = association.association_route
    reflection = ActiveRecord::Reflection::RuntimeReflection.new(association.reflection, association, route)

    assert_same route, reflection.association_route_for_join(Client, destination_class: Firm)
  end

  def test_route_writes_only_the_physical_reference_record
    reflection = Client.reflect_on_association(:firm)
    route = reflection.association_route
    client = Client.new
    firm = Firm.new(id: 42)

    route.write(client, firm)

    assert_equal 42, client.client_of
    assert_equal 42, firm.id
  end

  def test_route_writes_and_clears_references_in_both_directions
    link = ActiveRecord::AssociationLink.new(
      reference: build_mapping(reference_key: [:sponsorable_id, :club_id], target_key: [:id, :member_type_id]),
      constraints: build_mapping(reference_key: :sponsor_type, target_key: :name)
    )

    [ActiveRecord::AssociationRoute, ActiveRecord::AssociationRoute::Reverse].each_with_index do |route_class, index|
      reference = Sponsor.new(sponsorable_id: 1, club_id: 2, sponsorable_type: "Preserved type", sponsor_type: "Preserved constraint")
      target = Member.new(id: 42, member_type_id: 7, name: "Target constraint")
      target_attributes = target.attributes
      route = route_class.new(link: link, fixed_reference_values: { "sponsorable_type" => Member.polymorphic_name })
      origin, destination = index.zero? ? [reference, target] : [target, reference]

      route.write(origin, destination)

      assert_equal 42, reference.sponsorable_id
      assert_equal 7, reference.club_id
      assert_equal Member.polymorphic_name, reference.sponsorable_type
      assert_equal "Preserved constraint", reference.sponsor_type
      assert_equal target_attributes, target.attributes

      origin, destination = index.zero? ? [reference, nil] : [nil, reference]
      route.write(origin, destination)

      assert_nil reference.sponsorable_id
      assert_nil reference.club_id
      assert_equal Member.polymorphic_name, reference.sponsorable_type
      assert_equal "Preserved constraint", reference.sponsor_type
      assert_equal target_attributes, target.attributes
    end
  end

  def test_route_write_is_unconditional_unless_requested_otherwise
    reference = Client.new(client_of: "042")
    target = Firm.new(id: 42)
    route = Client.reflect_on_association(:firm).association_route

    route.write(reference, target, force: false)
    assert_equal "042", reference.client_of_before_type_cast

    route.write(reference, target)
    assert_equal 42, reference.client_of_before_type_cast

    reference.freeze
    assert_nothing_raised { route.write(reference, target, force: false) }
    assert_raises(FrozenError) { route.write(reference, target) }
  end

  def test_nil_route_write_clears_shared_primary_keys_without_compatibility_policy
    route = build_belongs_to_route(
      reference: { reference_key: [:id, :club_id], target_key: [:id, :member_type_id] },
      constraints: { reference_key: nil, target_key: nil }
    )
    reference = Sponsor.new(id: 42, club_id: 7)

    route.write(reference, nil)

    assert_nil reference.id
    assert_nil reference.club_id
  end

  def test_belongs_to_build_applies_scope_values_for_its_reference_key
    reference_class = Class.new(ActiveRecord::Base) do
      self.table_name = "comments"
      self.inheritance_column = nil

      def self.name = "ScopedReferenceKeyComment"

      belongs_to :routed_parent,
        -> { where(post_id: 42) },
        class_name: "Comment",
        foreign_key: :post_id,
        optional: true
    end
    reference = reference_class.new

    built = reference.association(:routed_parent).build(post_id: 7)

    assert_equal 42, built.post_id
  end

  def test_belongs_to_assignment_uses_the_assigned_subclass_key
    target_class = Class.new(Firm) do
      def self.name = "AlternatePrimaryKeyFirm"

      self.primary_key = :firm_id
    end
    firm = target_class.new(firm_id: 42)
    client = Client.new

    client.firm = firm

    assert_equal 42, client.client_of

    client.name = "Subclass key client"
    client.save!(validate: false)
    assert_equal client, Client.where(firm: firm).first
    assert_equal client, Client.find_by(firm: firm)
  end

  def test_equivalent_belongs_to_routes_group_sti_values
    post = Post.new(id: 1)
    special_post = SpecialPost.new(id: 2)

    assert_equal Comment.where(post_id: [post.id, special_post.id]).to_sql,
      Comment.where(post: [post, special_post]).to_sql
  end

  def test_belongs_to_route_uses_the_concrete_reference_class_aliases
    reference_class = Class.new(ActiveRecord::Base) do
      self.table_name = "comments"
      self.inheritance_column = nil

      def self.name = "AliasedRouteComment"

      alias_attribute :route_id, :post_id
      belongs_to :routed_post,
        class_name: "Post",
        foreign_key: :route_id,
        optional: true,
        inverse_of: false
    end
    subclass = Class.new(reference_class) do
      def self.name = "RemappedRouteComment"

      alias_attribute :route_id, :author_id
    end
    unrelated = Post.create!(title: "Unrelated", body: "Unrelated")
    target = Post.create!(title: "Target", body: "Target")
    replacement = Post.create!(title: "Replacement", body: "Replacement")
    reference = subclass.new(post_id: unrelated.id, author_id: target.id, body: "Reference")

    assert_equal target, reference.routed_post

    reference.routed_post = replacement
    reference.save!

    assert_equal unrelated.id, reference.post_id
    assert_equal replacement.id, reference.author_id
    assert_equal reference, subclass.find_by(routed_post: replacement)
    assert_equal [reference], subclass.where(routed_post: replacement).to_a
    assert_equal [reference.id], subclass.joins(:routed_post).where(posts: { id: replacement.id }).pluck(:id)
    assert_equal replacement, subclass.eager_load(:routed_post).find(reference.id).routed_post

    base = reference_class.create!(post_id: target.id, author_id: unrelated.id, body: "Base reference")
    reference.association(:routed_post).reset
    ActiveRecord::Associations::Preloader.new(records: [base, reference], associations: :routed_post).call

    assert_equal target, base.routed_post
    assert_equal replacement, reference.routed_post
  end

  def test_inverse_route_uses_the_concrete_origin_class_aliases
    origin_class = Class.new(NullableRoutePost) do
      def self.name = "AliasedRoutePost"

      alias_attribute :route_key, :id
      has_many :routed_comments,
        class_name: "AssociationRouteTest::InverseAliasedRouteComment",
        foreign_key: :route_fk,
        primary_key: :route_key,
        inverse_of: false
    end
    subclass = Class.new(origin_class) do
      def self.name = "RemappedRoutePost"

      alias_attribute :route_key, :author_id
    end
    owner = subclass.create!(
      id: 9_000_401,
      author_id: 9_000_402,
      title: "Inverse alias",
      body: "Inverse alias"
    )
    comment = InverseAliasedRouteComment.create!(post_id: owner.author_id, body: "Inverse alias comment")
    remapped = InverseRemappedRouteComment.new(body: "Remapped inverse alias")
    owner.association(:routed_comments).send(:set_owner_attributes, remapped)

    assert_equal owner.author_id, owner.routed_comments.build.post_id
    assert_equal owner.author_id, remapped.author_id
    assert_nil remapped.post_id
    assert_equal [comment], owner.routed_comments.reload.to_a
    joined = subclass.where(id: owner.id).joins(:routed_comments)
    assert_predicate joined, :exists?, joined.to_sql
    assert_equal [comment], subclass.eager_load(:routed_comments).find(owner.id).routed_comments
  end

  def test_association_reads_do_not_resolve_aliases_twice
    target = Post.create!(title: "Target", body: "Target")
    unrelated = Post.create!(title: "Unrelated", body: "Unrelated")
    row = NullableRouteComment.create!(post_id: target.id, author_id: unrelated.id, body: "Aliased reference")
    reference = DoubleAliasedRouteComment.find(row.id)

    assert_equal target.id, reference.read_attribute(:route_fk)
    assert_equal target, reference.routed_post
    assert_equal [reference], DoubleAliasedRouteComment.where(routed_post: target).to_a
    assert_equal reference, DoubleAliasedRouteComment.find_by(routed_post: target)
    assert_equal [reference.id], DoubleAliasedRouteComment.joins(:routed_post).where(posts: { id: target.id }).pluck(:id)
    assert_equal target, DoubleAliasedRouteComment.eager_load(:routed_post).find(reference.id).routed_post

    reference.association(:routed_post).reset
    ActiveRecord::Associations::Preloader.new(records: [reference], associations: :routed_post).call

    assert_equal target, reference.routed_post
  end

  def test_route_writes_do_not_resolve_fixed_value_aliases_twice
    owner_class = Class.new(NullableRoutePost) do
      def self.name = "AliasedTypeRouteOwner"

      has_many :routed_comments,
        as: :commentable,
        class_name: "AssociationRouteTest::DoubleAliasedTypeRouteComment",
        foreign_key: :post_id,
        foreign_type: :routed_type
    end
    owner = owner_class.new(id: 42)
    record = DoubleAliasedTypeRouteComment.new

    owner.association(:routed_comments).send(:set_owner_attributes, record)

    assert_equal owner.id, record.post_id
    assert_equal owner.class.polymorphic_name, record.routed_type
    assert_nil record.person_type
  end

  def test_composite_route_keys_preserve_aliases
    book = AliasedCompositeRouteBook.create!(id: [9_000_821, 9_000_822])
    review = AliasedCompositeRouteReview.create!(routed_book: book)
    route = review.association(:routed_book).association_route

    assert_equal ["route_author_id", "route_book_id"], route.origin_key.name
    assert_equal ["route_author_id", "route_book_id"], route.destination_key.name
    assert_equal book, review.reload.routed_book
    assert_equal [review], AliasedCompositeRouteReview.where(routed_book: book).to_a
    assert_equal review, AliasedCompositeRouteReview.find_by(routed_book: book)

    review.reload
    ActiveRecord::Associations::Preloader.new(records: [review], associations: :routed_book).call

    assert_equal book, review.routed_book
  end

  def test_routes_are_cached_by_concrete_query_constraints
    reflection = Client.reflect_on_association(:firm)
    first_class = Class.new(Client) do
      def self.name = "FirstRouteClient"
    end
    second_class = Class.new(Client) do
      def self.name = "SecondRouteClient"
    end
    first_constraints = build_mapping(reference_key: :name, target_key: :name)
    second_constraints = build_mapping(reference_key: :rating, target_key: :rating)
    constraints_for = lambda do |reference_class, _target_class|
      if reference_class == first_class
        first_constraints
      elsif reference_class == second_class
        second_constraints
      else
        ActiveRecord::Key::Mapping.empty
      end
    end

    reflection.clear_association_scope_cache
    reflection.stub(:association_route_constraints, constraints_for) do
      first_route = reflection.association_route(origin_class: first_class, destination_class: Firm)
      second_route = reflection.association_route(origin_class: second_class, destination_class: Firm)

      assert_equal first_constraints, first_route.link.constraints
      assert_equal second_constraints, second_route.link.constraints
    end
  ensure
    reflection&.clear_association_scope_cache
  end

  def test_polymorphic_route_resolves_the_target_key_for_each_destination_class
    reflection = PolymorphicComment.reflect_on_association(:person)
    author_route = reflection.association_route(destination_class: Author)
    person_route = reflection.association_route(destination_class: Person)

    assert_equal [["person_id", "author_code"]], author_route.link.reference.to_a
    assert_equal [["person_id", "external_id"]], person_route.link.reference.to_a
    assert_equal({ "person_type" => Author.polymorphic_name }, author_route.fixed_reference_values)
    assert_equal({ "person_type" => Person.polymorphic_name }, person_route.fixed_reference_values)
  end

  def test_inverse_polymorphic_route_has_the_same_physical_shape
    forward = Sponsor.reflect_on_association(:sponsorable).association_route(destination_class: Member)
    inverse = Member.reflect_on_association(:sponsor).association_route

    assert_equal forward.link.reference, inverse.link.reference
    assert_equal forward.origin_key, inverse.destination_key
    assert_equal forward.destination_key, inverse.origin_key
    assert_equal forward.fixed_reference_values, inverse.fixed_reference_values
    assert_empty forward.destination_fixed_values
    assert_equal inverse.fixed_reference_values, inverse.destination_fixed_values
  end

  def test_through_reflections_reject_single_edge_route_requests
    reflection = SelfRoutedCompany.reflect_on_association(:parents_mentor)

    assert_raises(ArgumentError) { reflection.association_route }
    assert_raises(ArgumentError) do
      reflection.association_route(origin_class: SelfRoutedCompany, destination_class: SelfRoutedCompany)
    end
    assert_not_respond_to reflection, :association_route_for_origin
    assert_not_respond_to reflection, :association_route_for_target
  end

  def test_source_route_is_only_exposed_on_through_reflections
    reflection = SelfRoutedCompany.reflect_on_association(:parents_mentor)

    assert_not_respond_to reflection.source_reflection, :source_association_route
    assert_equal [["client_of", "id"]], reflection.source_association_route.link.reference.to_a
  end

  def test_nested_source_route_resolves_the_terminal_edge
    reflection = SelfRoutedCompany.reflect_on_association(:parents_mentors_parent)

    assert_predicate reflection.source_reflection, :through_reflection?
    assert_equal [["firm_id", "id"]], reflection.source_association_route.link.reference.to_a
  end

  def test_source_route_preserves_the_through_source_type
    reflection = Tag.reflect_on_association(:tagged_posts)
    route = reflection.source_association_route

    assert_equal [["taggable_id", "id"]], route.link.reference.to_a
    assert_equal({ "taggable_type" => Post.polymorphic_name }, route.fixed_reference_values)
  end

  def test_through_route_chain_distinguishes_edges_with_the_same_endpoint_classes
    ancestor = SelfRoutedCompany.create!(name: "Mentor's parent")
    mentor = SelfRoutedCompany.create!(name: "Mentor", parent: ancestor)
    parent = SelfRoutedCompany.create!(name: "Parent", mentor: mentor)
    owner = SelfRoutedCompany.create!(name: "Owner", parent: parent)
    reflection = SelfRoutedCompany.reflect_on_association(:parents_mentor)
    routes = reflection.association_route_chain(origin_class: owner.class, destination_class: SelfRoutedCompany)

    assert_equal [[["client_of", "id"]], [["firm_id", "id"]]], routes.map { |route| route.link.reference.to_a }
    assert_equal mentor, owner.parents_mentor
    assert_equal [owner], SelfRoutedCompany.where(id: owner.id).joins(:parents_mentor).to_a
    assert_equal mentor, SelfRoutedCompany.eager_load(:parents_mentor).find(owner.id).parents_mentor
    assert_equal ancestor, owner.parents_mentors_parent
    assert_equal ancestor, SelfRoutedCompany.eager_load(:parents_mentors_parent).find(owner.id).parents_mentors_parent
  end

  def test_through_route_chain_preserves_the_supplied_destination_class
    destination_class = Class.new(SelfRoutedCompany) do
      def self.name = "AlternateRouteDestination"
      self.primary_key = :firm_id
    end
    reflection = SelfRoutedCompany.reflect_on_association(:parents_mentor)
    routes = reflection.association_route_chain(origin_class: SelfRoutedCompany, destination_class: destination_class)

    assert_equal [["client_of", "firm_id"]], routes.first.link.reference.to_a
    assert_equal [["firm_id", "id"]], routes.last.link.reference.to_a
  end

  def test_single_column_match_keys_load_scalar_and_composite_declarations
    post = SingletonRoutePost.create!(title: "Single-column target", body: "Single-column target")
    reference = SingletonRouteComment.create!(post_id: post.id_value, body: "Single-column reference")

    [:scalar_reference, :composite_reference, :composite_reference_and_target].each do |name|
      reflection = SingletonRouteComment.reflect_on_association(name)
      target = reflection.klass.find_by!(id: post.id_value)
      route = reflection.association_route

      assert_not_predicate route.origin_key, :composite?
      assert_not_predicate route.destination_key, :composite?
      assert_equal post.id_value, route.origin_key.value_of(reference)
      assert_equal post.id_value, route.destination_key.value_of(target)
      assert_equal target, reference.public_send(name)

      reference.association(name).reset
      ActiveRecord::Associations::Preloader.new(records: [reference], associations: name).call
      assert_predicate reference.association(name), :loaded?
      assert_equal target, reference.public_send(name)
    end
  end

  def test_through_preloading_handles_inherited_owner_reflections
    owner_class = Class.new(SelfRoutedCompany) do
      def self.name = "InheritedSelfRoutedCompany"
    end
    mentor = SelfRoutedCompany.create!(name: "Mentor")
    parent = SelfRoutedCompany.create!(name: "Parent", mentor: mentor)
    owner = owner_class.create!(name: "Owner", parent: parent)

    ActiveRecord::Associations::Preloader.new(records: [owner], associations: [:parents_mentor, :scoped_parents_mentor]).call

    assert_predicate owner.association(:parents_mentor), :loaded?
    assert_predicate owner.association(:scoped_parents_mentor), :loaded?
    assert_equal mentor, owner.parents_mentor
    assert_equal mentor, owner.scoped_parents_mentor
  end

  def test_polymorphic_inverse_through_route_uses_the_destination_class_aliases
    owner = InverseThroughRouteAuthor.create!(name: "Polymorphic inverse through")
    post = InverseThroughRoutePost.create!(author_id: owner.id, title: "Through", body: "Through")
    comment = InverseThroughRouteComment.create!(
      post_id: post.id, author_type: InverseThroughRoutePost.polymorphic_name, body: "Through comment"
    )

    assert_equal [comment], owner.polymorphic_route_comments.to_a
    assert_equal [comment], InverseThroughRouteAuthor.preload(:polymorphic_route_comments).find(owner.id).polymorphic_route_comments
    assert_equal [owner.id], InverseThroughRouteAuthor.joins(:polymorphic_route_comments).where(comments: { id: comment.id }).pluck(:id)
    assert_equal [comment], InverseThroughRouteAuthor.eager_load(:polymorphic_route_comments).find(owner.id).polymorphic_route_comments
  end

  def test_join_resolves_an_inverse_polymorphic_route_from_the_relation_model
    item = items(:dvd)
    tagging = taggings(:godfather)

    assert Item.joins(:tagging).where(items: { id: item.id }, taggings: { id: tagging.id }).exists?
  end

  def test_nested_through_route_uses_the_adjacent_class_for_an_inherited_polymorphic_inverse
    reference_class = Class.new(ActiveRecord::Base) do
      self.table_name = "sponsors"

      def self.name = "NestedRoutedReference"

      belongs_to :routed_item, class_name: "Item", foreign_key: :sponsorable_id
      has_one :routed_tagging, through: :routed_item, source: :tagging
    end
    item = items(:dvd)
    reference = reference_class.create!(sponsorable_id: item.id)

    assert_equal taggings(:godfather), reference.routed_tagging
  end

  def test_polymorphic_through_route_uses_the_concrete_origin_class
    item = RoutedItem.find(items(:dvd).id)

    assert_equal item.id, item.routed_item.id
  end

  def test_through_route_uses_the_concrete_intermediate_class_aliases
    owner = AliasedThroughRoutePost.create!(title: "Aliased through", body: "Aliased through")
    ship = Ship.create!(pirate_id: 9_000_411, name: "Aliased through ship")
    RemappedThroughRouteLink.create!(
      sponsorable_id: owner.id,
      club_id: -1,
      sponsor_id: ship.pirate_id
    )

    assert_equal [ship], owner.aliased_route_ships.to_a
    assert_equal [ship], AliasedThroughRoutePost.where(id: owner.id).preload(:aliased_route_ships).first.aliased_route_ships
    assert_equal [owner.id], AliasedThroughRoutePost.joins(:aliased_route_ships).where(ships: { id: ship.id }).pluck(:id)
  end

  def test_inverse_through_route_uses_the_destination_class_aliases
    owner = InverseThroughRouteAuthor.create!(name: "Inverse through")
    post = InverseThroughRoutePost.create!(author_id: owner.id, title: "Inverse through", body: "Inverse through")
    comment = InverseThroughRouteComment.create!(post_id: post.id, author_id: -1, body: "Inverse through comment")

    assert_equal [comment], owner.inverse_route_comments.to_a
    assert_equal [comment], InverseThroughRouteAuthor.where(id: owner.id).preload(:inverse_route_comments).first.inverse_route_comments
    assert_equal [owner.id], InverseThroughRouteAuthor.joins(:inverse_route_comments).where(comments: { id: comment.id }).pluck(:id)
  end

  def test_polymorphic_association_class_tracks_direct_type_changes
    sponsor = Sponsor.new(sponsorable_type: Member.polymorphic_name)
    association = sponsor.association(:sponsorable)

    assert_equal Member, association.klass

    sponsor.sponsorable_type = Firm.polymorphic_name

    assert_equal Company, association.klass
  end

  def test_polymorphic_association_class_uses_the_stored_sti_type_after_assignment
    sponsor = Sponsor.new
    sponsor.sponsorable = Firm.new

    assert_equal Company.polymorphic_name, sponsor.sponsorable_type
    assert_equal Company, sponsor.association(:sponsorable).klass
  end

  def test_polymorphic_assignment_ignores_an_unresolvable_stored_type
    member = Member.create!(name: "Replacement target")
    sponsor = Sponsor.new(sponsorable_id: -1, sponsorable_type: "MissingRoutedClass")

    assert_nothing_raised { sponsor.sponsorable = member }
    assert_same member, sponsor.sponsorable
    assert_equal member.id, sponsor.sponsorable_id
    assert_equal Member.polymorphic_name, sponsor.sponsorable_type
  end

  def test_empty_polymorphic_through_collection_can_be_cleared
    tag = Tag.create!(id: 9_000_001, name: "Unused route")

    assert_empty tag.tagged_posts
    assert_nothing_raised { tag.tagged_posts.clear }
  end

  def test_has_one_through_autosave_does_not_route_from_the_outer_owner
    origin_class = Class.new(ActiveRecord::Base) do
      self.table_name = "member_details"
      self.primary_key = [:organization_id, :member_id]

      def self.name = "CompositeThroughRouteOrigin"

      belongs_to :member
      has_one :routed_destination,
        through: :member,
        source: :admittable,
        source_type: "AssociationRouteTest::ThroughAutosaveDestination"
    end
    destination = ThroughAutosaveDestination.create!(firm_id: 42, name: "Through route")
    member = Member.create!(admittable: destination)
    origin = origin_class.create!(organization_id: 9_000_001, member_id: member.id, extra_data: "Before")
    assert_equal destination, origin.routed_destination

    origin.extra_data = "After"

    assert_nothing_raised { origin.save! }
  end

  def test_historical_polymorphic_route_resolves_an_aliased_type
    reference_class = Class.new(ActiveRecord::Base) do
      self.table_name = "comments"

      def self.name = "AliasedTypeRoutedReference"

      alias_attribute :routed_type, :author_type
      belongs_to :routed_target,
        polymorphic: true,
        foreign_key: :author_id,
        foreign_type: :routed_type,
        counter_cache: :legacy_comments_count,
        optional: true
    end
    reflection = reference_class.reflect_on_association(:routed_target)
    route = reflection.association_route(destination_class: Post)
    assert_equal({ "routed_type" => Post.polymorphic_name }, route.fixed_reference_values)

    target = Post.create!(title: "Aliased route", body: "Aliased route")
    target.update_column(:legacy_comments_count, 1)
    reference_class.insert_all!([
      {
        post_id: target.id,
        body: "Aliased route reference",
        author_id: target.id,
        author_type: Post.polymorphic_name,
      }
    ])
    reference = reference_class.find_by!(body: "Aliased route reference")

    reference.author_id = nil
    reference.save!

    assert_equal 0, target.reload.legacy_comments_count
  end

  def test_counter_decrement_reads_an_aliased_reference_before_last_save
    reference_class = Class.new(NullableRouteComment) do
      def self.name = "AliasedCounterReference"

      alias_attribute :route_fk, :post_id
      belongs_to :routed_post,
        class_name: "Post",
        foreign_key: :route_fk,
        counter_cache: :legacy_comments_count,
        optional: true
    end
    original = Post.create!(title: "Original", body: "Original")
    replacement = Post.create!(title: "Replacement", body: "Replacement")
    reference = reference_class.create!(routed_post: original, body: "Counter reference")
    assert_equal 1, original.reload.legacy_comments_count

    reference.update!(routed_post: replacement)

    assert_equal 0, original.reload.legacy_comments_count
    assert_equal 1, replacement.reload.legacy_comments_count
  end

  def test_touch_reads_an_aliased_reference_before_the_change
    reference_class = Class.new(ActiveRecord::Base) do
      self.table_name = "sponsors"
      def self.name = "AliasedTouchReference"

      alias_attribute :route_fk, :club_id
      belongs_to :routed_ship,
        class_name: "Ship",
        primary_key: :pirate_id,
        foreign_key: :route_fk,
        touch: true,
        optional: true
    end
    original = Ship.create!(pirate_id: 9_000_801, name: "Original")
    replacement = Ship.create!(pirate_id: 9_000_802, name: "Replacement")
    reference = reference_class.create!(routed_ship: original)
    original_time = Time.utc(2000, 1, 1)
    original.update_column(:updated_at, original_time)

    reference.update!(routed_ship: replacement)

    assert_operator original.reload.updated_at, :>, original_time
  end

  def test_touch_preserves_false_in_a_singleton_composite_reference
    assert_touch_preserves_singleton_reference(false)
  end

  def test_touch_preserves_nil_in_a_singleton_composite_reference
    assert_touch_preserves_singleton_reference(nil)
  end

  def test_touch_does_not_resolve_unchanged_missing_polymorphic_reference
    reference_class = Class.new(ActiveRecord::Base) do
      self.table_name = "sponsors"

      def self.name = "TouchRoutedReference"

      belongs_to :routed_target,
        polymorphic: true,
        foreign_key: :sponsorable_id,
        foreign_type: :sponsorable_type,
        touch: true,
        optional: true
    end
    target = Member.create!(name: "Touch route target")
    reference_class.insert_all!([
      { sponsorable_id: target.id, sponsorable_type: "MissingRoutedClass" }
    ])
    reference = reference_class.find_by!(sponsorable_type: "MissingRoutedClass")

    reference.sponsorable_type = Member.polymorphic_name

    assert_nothing_raised { reference.save! }

    reference_class.insert_all!([
      { club_id: 2, sponsorable_id: nil, sponsorable_type: "MissingRoutedClass" }
    ])
    reference = reference_class.find_by!(club_id: 2)
    assert_nothing_raised { reference.update!(routed_target: target) }
  end

  def test_partial_composite_reference_does_not_decrement_counters
    reference_class = Class.new(ActiveRecord::Base) do
      self.table_name = "sponsors"

      def self.name = "CompositeCounterReference"

      belongs_to :routed_post,
        class_name: "Post",
        foreign_key: [:club_id, :sponsorable_id],
        primary_key: [:author_id, :id],
        counter_cache: :legacy_comments_count,
        optional: true
    end
    post = Post.create!(author_id: 9_000_001, title: "Composite counter", body: "Composite counter")
    reference = reference_class.create!(club_id: 9_000_000, sponsorable_id: nil)
    association = reference.association(:routed_post)
    counter_changes = []

    association.stub(:update_counters_via_scope, ->(_klass, _values, by, _route) { counter_changes << by }) do
      reference.update!(club_id: post.author_id, sponsorable_id: post.id)
    end

    assert_equal [1], counter_changes
  end

  def test_inverse_polymorphic_route_keeps_constraints
    member = ConstrainedRouteMember.create!(member_type_id: 42)
    Sponsor.create!(club_id: 41, sponsorable: member)
    matching = Sponsor.create!(club_id: 42, sponsorable: member)
    reflection = ConstrainedRouteMember.reflect_on_association(:routed_sponsor)

    with_constraints(reflection, reference_key: :club_id, target_key: :member_type_id) do
      assert_equal matching, member.routed_sponsor
    end
  end

  def test_cached_association_reads_logical_inputs_from_each_owner
    first = posts(:welcome)
    second = Post.create!(title: "Second target", body: "Second target")
    reflection = DoubleAliasedRouteComment.reflect_on_association(:routed_post)
    routes = reflection.association_route_chain(origin_class: DoubleAliasedRouteComment, destination_class: Post)

    each_statement_mode do
      first_reference = DoubleAliasedRouteComment.new(route_fk: first.id, author_id: second.id)
      second_reference = DoubleAliasedRouteComment.new(route_fk: second.id, author_id: first.id)

      assert_equal first, first_reference.routed_post
      statement = reflection.association_scope_cache(Post, routes)
      assert_equal second, second_reference.routed_post
      assert_same statement, reflection.association_scope_cache(Post, routes)
    end
  end

  def test_cached_association_combines_owner_inputs_with_fixed_values
    first = Member.create!(member_type_id: 41)
    second = Member.create!(member_type_id: 42)
    first_target = Sponsor.create!(club_id: 41, sponsorable: first)
    second_target = Sponsor.create!(club_id: 42, sponsorable: second)
    Sponsor.create!(club_id: 42, sponsorable: first)
    Sponsor.create!(club_id: 41, sponsorable_id: first.id, sponsorable_type: Post.polymorphic_name)
    reflection = Member.reflect_on_association(:sponsor)

    with_constraints(reflection, reference_key: :club_id, target_key: :member_type_id) do
      routes = reflection.association_route_chain(origin_class: Member, destination_class: Sponsor)

      each_statement_mode do
        assert_equal first_target, first.reload_sponsor
        statement = reflection.association_scope_cache(Sponsor, routes)
        assert_equal second_target, second.reload_sponsor
        assert_same statement, reflection.association_scope_cache(Sponsor, routes)
      end
    end
  end

  def test_internal_query_constraints_apply_to_reads_but_not_writes
    reflection = Post.reflect_on_association(:comments)
    route = build_route(
      reference: { reference_key: :post_id, target_key: :id },
      constraints: { reference_key: :body, target_key: :title }
    )
    post = posts(:welcome)
    matching = Comment.create!(post_id: post.id, body: post.title)
    mismatching = Comment.create!(post_id: post.id, body: "Not the post title")

    reflection.stub(:association_route, route) do
      post.comments.load
      post.title = mismatching.body
      assert_not_predicate post.association(:comments), :stale_target?
      post.title = matching.body
      post.association(:comments).reset

      assert_equal [matching], post.comments.where(id: [matching.id, mismatching.id]).to_a

      built = post.comments.build
      assert_equal post.id, built.post_id
      assert_nil built.body
      assert_equal "Manual", post.comments.where(body: "Manual").build.body
      assert_equal "Explicit", post.comments.create_with(body: "Explicit").build.body

      preloaded = Post.where(id: post.id).preload(:comments).first
      assert_includes preloaded.comments, matching
      assert_not_includes preloaded.comments, mismatching

      assert Post.joins(:comments).where(posts: { id: post.id }, comments: { id: matching.id }).exists?
      assert_not Post.joins(:comments).where(posts: { id: post.id }, comments: { id: mismatching.id }).exists?
    end
  end

  def test_reference_update_checks_writable_values_but_not_query_constraints
    link = ActiveRecord::AssociationLink.new(
      reference: build_mapping(reference_key: [:sponsorable_id, :club_id], target_key: [:id, :member_type_id]),
      constraints: build_mapping(reference_key: :sponsor_type, target_key: :name)
    )

    [ActiveRecord::AssociationRoute, ActiveRecord::AssociationRoute::Reverse].each_with_index do |route_class, index|
      reference = Sponsor.new(sponsorable_id: 42, club_id: 7, sponsorable_type: Member.polymorphic_name, sponsor_type: "Different constraint")
      target = Member.new(id: 42, member_type_id: 7, name: "Target constraint")
      origin, destination = index.zero? ? [reference, target] : [target, reference]
      route = route_class.new(link: link, fixed_reference_values: { "sponsorable_type" => Member.polymorphic_name })

      assert_not route.reference_needs_update?(origin, destination)
      reference.club_id = 8
      assert route.reference_needs_update?(origin, destination)
      reference.club_id = 7
      reference.sponsorable_type = "Other"
      assert route.reference_needs_update?(origin, destination)
      assert_equal "Other", reference.sponsorable_type
      assert_equal "Different constraint", reference.sponsor_type
    end
  end

  def test_reference_update_does_not_infer_key_changes_from_unselected_attributes
    link = ActiveRecord::AssociationLink.new(
      reference: build_mapping(reference_key: [:sponsorable_id, :club_id], target_key: [:id, :member_type_id])
    )
    route = ActiveRecord::AssociationRoute.new(link: link, fixed_reference_values: { "sponsorable_type" => Member.polymorphic_name })
    reference = Sponsor.instantiate("id" => 1, "club_id" => 7, "sponsorable_type" => Member.polymorphic_name)
    target = Member.new(id: 42, member_type_id: 7)

    assert_not reference.has_attribute?(:sponsorable_id)
    assert_not route.reference_needs_update?(reference, target)
    reference.sponsorable_type = "Other"
    assert route.reference_needs_update?(reference, target)
  end

  def test_origin_reference_completeness_ignores_query_constraints
    link = ActiveRecord::AssociationLink.new(
      reference: build_mapping(reference_key: [:author_id, :post_id], target_key: [:author_id, :id]),
      constraints: build_mapping(reference_key: :body, target_key: :title)
    )
    forward = ActiveRecord::AssociationRoute.new(link: link)
    reverse = ActiveRecord::AssociationRoute::Reverse.new(link: link)
    reference = Comment.new(author_id: 7, post_id: 42, body: nil)
    target = Post.new(author_id: 7, id: 42, title: nil)

    assert forward.origin_reference_complete?(reference)
    assert reverse.origin_reference_complete?(target)
    reference.author_id = nil
    target.author_id = nil
    assert_not forward.origin_reference_complete?(reference)
    assert_not reverse.origin_reference_complete?(target)
  end

  def test_origin_reference_completeness_retains_false_values
    route = BooleanRouteBook.reflect_on_association(:boolean_route_comments).association_route

    assert route.origin_reference_complete?(BooleanRouteBook.new(boolean_status: false))
    assert_not route.origin_reference_complete?(BooleanRouteBook.new(boolean_status: nil))
  end

  def test_key_values_match_normalizes_and_checks_the_complete_mapping
    link = ActiveRecord::AssociationLink.new(
      reference: build_mapping(reference_key: :post_id, target_key: :id),
      constraints: build_mapping(reference_key: :body, target_key: :author_id)
    )

    [ActiveRecord::AssociationRoute, ActiveRecord::AssociationRoute::Reverse].each_with_index do |route_class, index|
      reference = Comment.new(post_id: 42, body: "7")
      target = Post.new(id: 42, author_id: 7)
      origin, destination = index.zero? ? [reference, target] : [target, reference]
      route = route_class.new(link: link)

      assert route.key_values_match?(origin, destination)
      reference.body = "8"
      assert_not route.key_values_match?(origin, destination)
      reference.body = "7"
      reference.post_id = 43
      assert_not route.key_values_match?(origin, destination)
    end
  end

  def test_matching_origins_prepare_each_class_once_and_preserve_order
    string_link_class = Class.new(ConstrainedRouteLink) do
      attribute :club_id, :string
    end
    preparations = []
    route_class = Class.new(ActiveRecord::AssociationRoute) do
      define_method(:match_normalizers) do |**classes|
        preparations << classes[:origin_class]
        super(**classes)
      end
    end
    route = route_class.new(link: ActiveRecord::AssociationLink.new(
      reference: build_mapping(reference_key: :club_id, target_key: :pirate_id)
    ))
    first = ConstrainedRouteLink.new(club_id: 42)
    second = string_link_class.new(club_id: "42")
    miss = ConstrainedRouteLink.new(club_id: 43)
    destination = Ship.new(pirate_id: 42)
    reader = destination.method(:read_attribute)
    reads = []

    destination.stub(:read_attribute, ->(column) { reads << column; reader.call(column) }) do
      assert_equal [first, second, first], route.each_matching_origin([first, second, miss, first], destination).to_a
    end

    assert_equal [ConstrainedRouteLink, string_link_class], preparations
    assert_equal ["pirate_id", "pirate_id"], reads
  end

  def test_matching_origins_do_not_retain_values_between_enumerations
    route = ConstrainedRouteLink.reflect_on_association(:ship).association_route
    first = ConstrainedRouteLink.new(club_id: 42)
    second = ConstrainedRouteLink.new(club_id: 43)
    destination = Ship.new(pirate_id: 42)
    matches = route.each_matching_origin([first, second], destination)

    assert_equal [first], matches.to_a
    destination.pirate_id = 43
    assert_equal [second], matches.to_a
  end

  def test_matching_origins_preserve_nil_and_false_destination_values
    route = build_belongs_to_route(
      reference: { reference_key: :boolean_status, target_key: :boolean_status },
      constraints: { reference_key: nil, target_key: nil }
    )
    origins = [nil, false, false].map { |value| BooleanRouteBook.new(boolean_status: value) }

    [nil, false].each do |value|
      destination = BooleanRouteBook.new(boolean_status: value)
      reader = destination.method(:read_attribute)
      reads = []
      destination.stub(:read_attribute, ->(column) { reads << column; reader.call(column) }) do
        assert_equal origins.select { |origin| origin.boolean_status == value }, route.each_matching_origin(origins, destination).to_a
      end
      assert_equal ["boolean_status"], reads
    end
  end

  def test_matching_origins_check_the_complete_mapping_in_both_directions
    link = ActiveRecord::AssociationLink.new(
      reference: build_mapping(reference_key: :post_id, target_key: :id),
      constraints: build_mapping(reference_key: :body, target_key: :author_id)
    )
    [ActiveRecord::AssociationRoute, ActiveRecord::AssociationRoute::Reverse].each do |route_class|
      route = route_class.new(link: link)
      if route_class == ActiveRecord::AssociationRoute
        destination = Post.new(id: 42, author_id: 7)
        origins = [Comment.new(post_id: 42, body: "7"), Comment.new(post_id: 42, body: "8"), Comment.new(post_id: 43, body: "7")]
      else
        destination = Comment.new(post_id: 42, body: "7")
        origins = [Post.new(id: 42, author_id: 7), Post.new(id: 42, author_id: 8), Post.new(id: 43, author_id: 7)]
      end

      assert_equal [origins.first], route.each_matching_origin(origins, destination).to_a
    end
  end

  def test_match_normalizers_are_absent_for_matching_types
    route = Client.reflect_on_association(:firm).association_route

    assert_equal [nil, nil], route.match_normalizers(origin_class: Client, destination_class: Firm)
  end

  def test_match_normalizers_convert_each_column_pair_independently
    route = build_belongs_to_route(
      reference: { reference_key: :body, target_key: :id },
      constraints: { reference_key: :author_id, target_key: :author_id }
    )
    origin_normalizers, destination_normalizers = route.match_normalizers(origin_class: Comment, destination_class: Post)
    origin = Comment.new(author_id: 7, body: "42")
    destination = Post.new(author_id: 7, id: 42)

    assert_equal 2, origin_normalizers.length
    assert_equal 2, destination_normalizers.length
    assert_nil origin_normalizers.first
    assert_nil destination_normalizers.first
    assert_equal [7, "42"], route.origin_key.value_of(origin, origin_normalizers)
    assert_equal [7, "42"], route.destination_key.value_of(destination, destination_normalizers)
    assert_predicate origin_normalizers, :frozen?
    assert_predicate destination_normalizers, :frozen?
  end

  def test_match_normalizers_preserve_nil_and_convert_false
    route = BooleanRouteBook.reflect_on_association(:boolean_route_comments).association_route
    origin_normalizers, destination_normalizers = route.match_normalizers(origin_class: BooleanRouteBook, destination_class: Comment)
    origin = BooleanRouteBook.new(boolean_status: false)
    destination = Comment.new(author_type: "false")

    assert_equal "false", route.origin_key.value_of(origin, origin_normalizers)
    assert_equal "false", route.destination_key.value_of(destination, destination_normalizers)
    assert_nil origin_normalizers.first.call(nil)
    assert_nil destination_normalizers.first.call(nil)
  end

  def test_match_normalizers_allow_endpoint_specific_conversions_using_type_objects
    types_seen = []
    parse_integer = ->(value) { value&.to_i }
    link = ActiveRecord::AssociationLink.new(reference: build_mapping(reference_key: :body, target_key: :id))
    comment = Comment.new(body: "42")
    post = Post.new(id: 42)

    [ActiveRecord::AssociationRoute, ActiveRecord::AssociationRoute::Reverse].each_with_index do |base_route_class, index|
      route_class = Class.new(base_route_class) do
        define_method(:normalizers_for_types) do |origin_type, destination_type|
          types_seen << [origin_type, destination_type]
          [origin_type.type == :text ? parse_integer : nil, destination_type.type == :text ? parse_integer : nil]
        end
        private :normalizers_for_types
      end
      origin, destination = index.zero? ? [comment, post] : [post, comment]
      route = route_class.new(link: link)
      origin_normalizers, destination_normalizers = route.match_normalizers(origin_class: origin.class, destination_class: destination.class)

      assert_same origin.class.type_for_attribute(route.origin_key.name), types_seen[index].first
      assert_same destination.class.type_for_attribute(route.destination_key.name), types_seen[index].last
      assert_equal 42, route.origin_key.value_of(origin, origin_normalizers)
      assert_equal 42, route.destination_key.value_of(destination, destination_normalizers)
      assert_nil index.zero? ? destination_normalizers : origin_normalizers
    end
  end

  def test_preloader_keeps_false_reference_values_after_type_conversion
    book = BooleanRouteBook.create!(boolean_status: false)
    comment = Comment.create!(post_id: -1, body: "Boolean route", author_type: "false")

    ActiveRecord::Associations::Preloader.new(records: [book], associations: :boolean_route_comments).call

    assert_equal [comment], book.boolean_route_comments
  end

  def test_preloader_converts_each_match_key_pair_independently
    reference_class = Class.new(ActiveRecord::Base) do
      self.table_name = "comments"
      self.inheritance_column = nil

      def self.name = "TypedRouteComment"

      belongs_to :routed_post,
        class_name: "Post",
        foreign_key: :body,
        primary_key: :id,
        optional: true
    end
    post = Post.create!(author_id: 9_000_201, title: "Typed route", body: "Typed route")
    reference = reference_class.create!(post_id: -1, author_id: post.author_id, body: post.id.to_s)
    reflection = reference_class.reflect_on_association(:routed_post)
    route = build_belongs_to_route(
      reference: { reference_key: :body, target_key: :id },
      constraints: { reference_key: :author_id, target_key: :author_id }
    )

    reflection.stub(:association_route, route) do
      ActiveRecord::Associations::Preloader.new(
        records: [reference],
        associations: :routed_post,
        available_records: [post]
      ).call
    end

    assert_equal post, reference.routed_post
  end

  def test_empty_association_array_predicate_is_false
    assert_empty Client.where(firm: [])
  end

  def test_association_predicate_combines_scalar_ids_and_nil_in_either_order
    firm = Firm.create!(name: "Predicate firm")
    associated = Client.create!(name: "Associated client", firm: firm)
    unassociated = Client.new(name: "Unassociated client")
    unassociated.save!(validate: false)
    expected = [associated, unassociated].sort_by(&:id)

    assert_equal expected, Client.where(firm: [nil, firm.id]).order(:id).to_a
    assert_equal expected, Client.where(firm: [firm.id, nil]).order(:id).to_a
  end

  def test_nil_association_predicate_preserves_scalar_and_composite_reference_shapes
    [
      [:post_id, :id, { "post_id" => nil }],
      [[:post_id], [:id], { "post_id" => nil }],
      [[:author_id, :post_id], [:author_id, :id], { "author_id" => nil, "post_id" => nil }],
    ].each do |foreign_key, primary_key, expected|
      reflection = ActiveRecord::Reflection.create(:belongs_to, :post, nil,
        { class_name: "Post", foreign_key: foreign_key, primary_key: primary_key }, NullableRouteComment)
      value = ActiveRecord::PredicateBuilder::AssociationQueryValue.new(reflection, nil, NullableRouteComment)

      assert_equal [expected], value.queries
    end
  end

  def test_nil_association_predicate_uses_only_the_reference
    reference_class = Class.new(ActiveRecord::Base) do
      self.table_name = "sponsors"

      def self.name = "NilPredicateReference"

      belongs_to :routed_ship,
        class_name: "Ship",
        foreign_key: :club_id,
        primary_key: :pirate_id,
        optional: true
    end
    reference = reference_class.create!(club_id: nil, sponsorable_type: "Present constraint")
    reflection = reference_class.reflect_on_association(:routed_ship)
    route = build_belongs_to_route(
      reference: { reference_key: :club_id, target_key: :pirate_id },
      constraints: { reference_key: :sponsorable_type, target_key: :name }
    )

    reflection.stub(:association_route, route) do
      assert_includes reference_class.where(routed_ship: nil), reference
      assert_includes reference_class.where(routed_ship: [nil]), reference

      target = Ship.new(pirate_id: nil, name: reference.sponsorable_type)
      assert_equal reference, reference_class.where(routed_ship: target).first
      assert_equal reference, reference_class.find_by(routed_ship: target)
    end
  end

  def test_scalar_association_predicate_uses_only_the_reference
    reference_class = Class.new(ActiveRecord::Base) do
      self.table_name = "sponsors"

      def self.name = "ScalarPredicateReference"

      belongs_to :routed_ship,
        class_name: "Ship",
        foreign_key: :club_id,
        primary_key: :pirate_id,
        optional: true
    end
    target = Ship.create!(pirate_id: 9_000_051, name: "Scalar predicate")
    reference = reference_class.create!(club_id: target.pirate_id, sponsorable_type: "Different constraint")
    reflection = reference_class.reflect_on_association(:routed_ship)
    route = build_belongs_to_route(
      reference: { reference_key: :club_id, target_key: :pirate_id },
      constraints: { reference_key: :sponsorable_type, target_key: :name }
    )

    reflection.stub(:association_route, route) do
      assert_equal reference, reference_class.where(routed_ship: target.pirate_id).first
      assert_equal reference, reference_class.find_by(routed_ship: target.pirate_id)
    end
  end

  def test_polymorphic_relation_predicate_uses_the_complete_match
    reference_class = Class.new(ActiveRecord::Base) do
      self.table_name = "sponsors"

      def self.name = "ConstrainedPolymorphicReference"

      belongs_to :subject,
        polymorphic: true,
        foreign_key: :club_id,
        foreign_type: :sponsorable_type,
        optional: true
    end
    post = Post.create!(title: "Polymorphic relation", body: "Polymorphic relation")
    reference = reference_class.create!(club_id: post.id, sponsor_type: post.title, sponsorable_type: Post.polymorphic_name)
    reflection = reference_class.reflect_on_association(:subject)

    with_constraints(reflection, reference_key: :sponsor_type, target_key: :title) do
      assert_equal [reference], reference_class.where(subject: Post.where(id: post.id)).to_a
      assert_empty reference_class.where(subject: Post.none)
    end
  end

  def test_empty_constrained_association_predicates_are_false
    reflection = Comment.reflect_on_association(:post)
    route = build_belongs_to_route(
      reference: { reference_key: :post_id, target_key: :id },
      constraints: { reference_key: :body, target_key: :title }
    )

    reflection.stub(:association_route, route) do
      assert_empty Comment.where(post: [])
      assert_empty Comment.where(post: Post.none)
    end
  end

  def test_empty_association_predicate_is_false_for_array_constraint
    skip unless current_adapter?(:PostgreSQLAdapter)

    ArrayRouteRecord.create!(big_int_data_points: [])
    reflection = ArrayRouteRecord.reflect_on_association(:same_row)

    with_constraints(reflection, reference_key: :big_int_data_points, target_key: :big_int_data_points) do
      assert_empty ArrayRouteRecord.where(same_row: [])
      assert_empty ArrayRouteRecord.where(same_row: ArrayRouteRecord.none)
    end
  end

  def test_normalized_single_column_match_preserves_array_valued_scalars
    skip unless current_adapter?(:PostgreSQLAdapter)

    record = ArrayRouteRecord.create!(big_int_data_points: [10, 20])
    route = ArrayRouteRecord.reflect_on_association(:same_array).association_route

    assert_not_predicate route.origin_key, :composite?
    assert_not_predicate route.destination_key, :composite?
    assert_equal [10, 20], route.origin_key.value_of(record)
    assert_equal [10, 20], route.destination_key.value_of(record)
    assert_equal record, record.same_array

    record.association(:same_array).reset
    ActiveRecord::Associations::Preloader.new(records: [record], associations: :same_array).call
    assert_predicate record.association(:same_array), :loaded?
    assert_equal record, record.same_array
  end

  def test_find_by_preserves_array_valued_query_constraint
    skip unless current_adapter?(:PostgreSQLAdapter)

    record = ArrayRouteRecord.create!(big_int_data_points: [10, 20])
    reflection = ArrayRouteRecord.reflect_on_association(:same_row)

    with_constraints(reflection, reference_key: :big_int_data_points, target_key: :big_int_data_points) do
      assert_equal record, ArrayRouteRecord.where(same_row: record).first
      assert_equal record, ArrayRouteRecord.find_by(same_row: record)
    end
  end

  def test_disable_joins_constraints_do_not_become_creation_defaults
    author = Author.create!(name: "Constrained author")
    post = Post.create!(author: author, title: "Constrained post", body: "Post body")
    comment = Comment.create!(post: post, body: post.title)
    reflection = Post.reflect_on_association(:comments)
    route = build_route(
      reference: { reference_key: :post_id, target_key: :id },
      constraints: { reference_key: :body, target_key: :title }
    )

    reflection.stub(:association_route, route) do
      scope = author.association(:no_joins_comments).scope
      assert_equal [comment], scope.to_a
      assert_not scope.scope_for_create.key?("body")
    end
  end

  def test_query_constraints_identify_counter_cache_destinations
    reference_class = Class.new(ActiveRecord::Base) do
      self.table_name = "comments"
      self.inheritance_column = nil

      def self.name = "ConstrainedCounterReference"

      belongs_to :routed_post,
        class_name: "Post",
        foreign_key: :author_id,
        primary_key: :author_id,
        counter_cache: :legacy_comments_count,
        optional: true
    end
    reflection = reference_class.reflect_on_association(:routed_post)
    route = build_belongs_to_route(
      reference: { reference_key: :author_id, target_key: :author_id },
      constraints: { reference_key: :deleted_at, target_key: :deleted_at }
    )
    old_post = Post.create!(author_id: 9_000_101, title: "Old constrained post", body: "Old")
    decoy = Post.create!(author_id: old_post.author_id, title: "Decoy constrained post", body: "Decoy", deleted_at: Time.utc(2000))
    new_post = Post.create!(author_id: 9_000_102, title: "New constrained post", body: "New", deleted_at: Time.utc(2001))
    old_post.update_column(:legacy_comments_count, 1)
    decoy.update_column(:legacy_comments_count, 1)
    reference_class.insert_all!([
      {
        post_id: -1,
        author_id: old_post.author_id,
        body: "Constrained reference",
        deleted_at: old_post.deleted_at,
      }
    ])
    reference = reference_class.find_by!(author_id: old_post.author_id, deleted_at: nil)

    reflection.stub(:association_route, route) do
      assert_equal reference, reference_class.where(routed_post: old_post).first
      assert_equal reference, reference_class.find_by(routed_post: old_post)

      reference.author_id = new_post.author_id
      reference.deleted_at = new_post.deleted_at
      reference.save!
    end

    assert_equal 0, old_post.reload.legacy_comments_count
    assert_equal 1, decoy.reload.legacy_comments_count
    assert_equal 1, new_post.reload.legacy_comments_count
  end

  def test_query_constraints_identify_touch_destinations
    reference_class = Class.new(ActiveRecord::Base) do
      self.table_name = "sponsors"

      def self.name = "ConstrainedTouchReference"

      belongs_to :routed_ship,
        class_name: "Ship",
        foreign_key: :club_id,
        primary_key: :pirate_id,
        touch: true,
        optional: true
    end
    reflection = reference_class.reflect_on_association(:routed_ship)
    route = build_belongs_to_route(
      reference: { reference_key: :club_id, target_key: :pirate_id },
      constraints: { reference_key: :sponsorable_type, target_key: :name }
    )
    original_time = Time.utc(2000)
    decoy = Ship.create!(name: "Decoy constrained ship", pirate_id: 9_000_111, updated_at: original_time)
    old_ship = Ship.create!(name: "Old constrained ship", pirate_id: decoy.pirate_id, updated_at: original_time)
    new_ship = Ship.create!(name: "New constrained ship", pirate_id: 9_000_112, updated_at: original_time)
    reference_class.insert_all!([
      {
        club_id: old_ship.pirate_id,
        sponsorable_id: -1,
        sponsorable_type: old_ship.name,
      }
    ])
    reference = reference_class.find_by!(sponsorable_type: old_ship.name)

    reflection.stub(:association_route, route) do
      reference.club_id = new_ship.pirate_id
      reference.sponsorable_type = new_ship.name
      reference.save!
    end

    assert_operator old_ship.reload.updated_at, :>, original_time
    assert_equal original_time, decoy.reload.updated_at
  end

  def test_query_constraints_identify_async_destruction_destinations
    reference_class = Class.new(ActiveRecord::Base) do
      self.table_name = "comments"
      self.inheritance_column = nil

      def self.name = "ConstrainedAsyncReference"

      belongs_to :routed_post,
        class_name: "Post",
        foreign_key: :author_id,
        primary_key: :author_id,
        optional: true
    end
    reflection = reference_class.reflect_on_association(:routed_post)
    reflection.options[:dependent] = :destroy_async
    route = build_belongs_to_route(
      reference: { reference_key: :author_id, target_key: :author_id },
      constraints: { reference_key: :body, target_key: :title }
    )
    post = Post.create!(author_id: 9_000_121, title: "Async constrained post", body: "Async")
    reference = reference_class.create!(post_id: -1, author_id: post.author_id, body: post.title)
    association = reference.association(:routed_post)
    enqueued = nil

    reflection.stub(:association_route, route) do
      association.stub(:enqueue_destroy_association, ->(**options) { enqueued = options }) do
        association.handle_dependency
      end
    end

    assert_equal Post.to_s, enqueued[:association_class]
    assert_equal [[post.title, post.author_id]], enqueued[:association_ids]
    assert_equal ["title", "author_id"], enqueued[:association_primary_key_column]
  end

  def test_async_destruction_uses_the_loaded_destination_match
    reference_class = Class.new(ActiveRecord::Base) do
      self.table_name = "comments"
      self.inheritance_column = nil

      def self.name = "LoadedAsyncReference"

      belongs_to :routed_post,
        class_name: "Post",
        foreign_key: :author_id,
        primary_key: :author_id,
        optional: true
    end
    reflection = reference_class.reflect_on_association(:routed_post)
    reflection.options[:dependent] = :destroy_async
    route = build_belongs_to_route(
      reference: { reference_key: :author_id, target_key: :author_id },
      constraints: { reference_key: :body, target_key: :title }
    )
    original = Post.create!(author_id: 9_000_131, title: "Original", body: "Original")
    replacement = Post.create!(author_id: original.author_id, title: "Replacement", body: "Replacement")
    reference = reference_class.create!(post_id: -1, author_id: original.author_id, body: original.title)
    association = reference.association(:routed_post)
    enqueued = nil

    persisted_title = replacement.title
    persisted_author_id = replacement.author_id
    reflection.stub(:association_route, route) do
      reference.routed_post = replacement
      replacement.title = "Unsaved title"
      replacement.author_id = 9_000_132
      association.stub(:enqueue_destroy_association, ->(**options) { enqueued = options }) do
        association.handle_dependency
      end
    end

    assert_equal [[persisted_title, persisted_author_id]], enqueued[:association_ids]
  end

  def test_async_destruction_falls_back_to_owner_values_for_unselected_columns
    reference_class = Class.new(ActiveRecord::Base) do
      self.table_name = "comments"
      self.inheritance_column = nil

      def self.name = "PartialAsyncComment"

      belongs_to :routed_post,
        -> { select(:title) },
        class_name: "Post",
        foreign_key: :post_id,
        optional: true
    end
    reflection = reference_class.reflect_on_association(:routed_post)
    reflection.options[:dependent] = :destroy_async
    post = Post.create!(title: "Partial async target", body: "Partial async target")
    reference = reference_class.create!(post_id: post.id, body: "Partial async reference")
    association = reference.association(:routed_post)
    enqueued = nil

    association.load_target
    association.stub(:enqueue_destroy_association, ->(**options) { enqueued = options }) do
      association.handle_dependency
    end

    assert_equal [post.id], enqueued[:association_ids]
  end

  def test_async_destruction_preserves_logical_keys_and_the_declared_class
    post = RemappedAsyncRoutePost.create!(author_id: 9_000_811, title: "Async alias", body: "Async alias")
    reference = AliasedAsyncRouteComment.create!(routed_post: post, body: "Async reference")
    reflection = AliasedAsyncRouteComment.reflect_on_association(:routed_post)
    reflection.options[:dependent] = :destroy_async
    association = reference.association(:routed_post)
    enqueued = nil

    association.stub(:enqueue_destroy_association, ->(**options) { enqueued = options }) do
      association.handle_dependency
    end

    assert_equal AliasedAsyncRoutePost.name, enqueued[:association_class]
    assert_equal "route_key", enqueued[:association_primary_key_column]
    assert_equal [post.id], enqueued[:association_ids]
  end

  def test_async_destruction_identity_follows_the_selected_key_shape
    post = SingletonRoutePost.create!(title: "Key-shaped identity", body: "Key-shaped identity")
    reference = SingletonRouteComment.new(post_id: post.id_value)
    association = reference.association(:scalar_reference)
    association.load_target
    route = association.association_route(association.target)

    assert_equal post.id_value, association.send(:destroy_association_async_id, route, route.destination_key)
    assert_equal [post.id_value], association.send(:destroy_association_async_id, route, route.reference_destination_key)
  end

  def test_async_destruction_uses_scalar_payloads_for_single_column_scalar_values
    post = SingletonRoutePost.create!(title: "Single-column async", body: "Single-column async")
    reference = SingletonRouteComment.create!(post_id: post.id_value, body: "Single-column async")

    [:scalar_reference, :composite_reference, :composite_reference_and_target].each do |name|
      association = reference.association(name)
      association.reflection.options[:dependent] = :destroy_async
      association.load_target
      enqueued = nil

      association.stub(:enqueue_destroy_association, ->(**options) { enqueued = options }) do
        association.handle_dependency
      end

      assert_equal "id", enqueued[:association_primary_key_column]
      assert_equal [post.id_value], enqueued[:association_ids]
    end
  end

  def test_async_destruction_reads_physical_composite_key_columns
    reference_class = Class.new(ActiveRecord::Base) do
      self.table_name = "cpk_reviews"

      def self.name = "CompositeAsyncReference"

      belongs_to :routed_book,
        class_name: "Cpk::Book",
        foreign_key: [:author_id, :number],
        primary_key: [:author_id, :id],
        optional: true
    end
    reflection = reference_class.reflect_on_association(:routed_book)
    reflection.options[:dependent] = :destroy_async
    book = Cpk::Book.create!(id: [9_000_141, 9_000_142])
    reference = reference_class.create!(author_id: book.author_id, number: book.id_value)
    association = reference.association(:routed_book)
    enqueued = nil

    association.load_target
    association.stub(:enqueue_destroy_association, ->(**options) { enqueued = options }) do
      association.handle_dependency
    end

    assert_equal [[book.author_id, book.id_value]], enqueued[:association_ids]
  end

  def test_through_deletion_uses_the_complete_match
    post = ConstrainedRoutePost.create!(title: "Constrained through", body: "Constrained through")
    first = Ship.create!(pirate_id: 9_000_301, name: "First constrained ship")
    second = Ship.create!(pirate_id: first.pirate_id, name: "Second constrained ship")
    first_link = ConstrainedRouteLink.create!(sponsorable_id: post.id, club_id: first.pirate_id, sponsor_type: first.name)
    second_link = ConstrainedRouteLink.create!(sponsorable_id: post.id, club_id: second.pirate_id, sponsor_type: second.name)
    reflection = ConstrainedRouteLink.reflect_on_association(:ship)

    with_constraints(reflection, reference_key: :sponsor_type, target_key: :name) do
      assert_equal [first, second], post.route_ships.order(:id).to_a
      post.route_links.load
      post.route_ships.delete(first)
    end

    assert_not ConstrainedRouteLink.exists?(first_link.id)
    assert ConstrainedRouteLink.exists?(second_link.id)
    assert_equal [second_link], post.route_links.to_a
  end

  def test_deleting_an_unsaved_through_target_preserves_other_join_records
    post = Post.new(title: "Unsaved through", body: "Unsaved through")
    first = Tag.new(name: "First unsaved tag")
    second = Tag.new(name: "Second unsaved tag")

    post.tags.concat(first, second)
    assert_equal [first, second], post.taggings.map(&:tag)

    post.tags.delete(first)

    assert_equal [second], post.taggings.map(&:tag)
  end

  def test_sti_source_type_deletion_updates_the_loaded_through_cache
    author = Author.create!(name: "STI source type author")
    author.books.load
    hardback = BestHardback.create!
    author.best_hardbacks << hardback
    join = author.books.find { |book| book.format_record == hardback }

    author.best_hardbacks.delete(hardback)

    assert_not Book.exists?(join.id)
    assert_not_includes author.books, join
  end

  def test_through_deletion_matches_loaded_keys_after_type_conversion
    post = ConstrainedRoutePost.create!(title: "Typed through", body: "Typed through")
    first = Ship.create!(pirate_id: 9_000_321, name: "First typed ship")
    second = Ship.create!(pirate_id: first.pirate_id, name: "Second typed ship")
    first_link = ConstrainedRouteLink.create!(
      sponsorable_id: post.id,
      sponsorable_type: first.id.to_s,
      club_id: first.pirate_id
    )
    second_link = ConstrainedRouteLink.create!(
      sponsorable_id: post.id,
      sponsorable_type: second.id.to_s,
      club_id: second.pirate_id
    )
    reflection = ConstrainedRouteLink.reflect_on_association(:ship)
    route = build_belongs_to_route(
      reference: { reference_key: :club_id, target_key: :pirate_id },
      constraints: { reference_key: :sponsorable_type, target_key: :id }
    )

    post.route_links.load
    reflection.stub(:association_route, route) do
      post.route_ships.delete(first)
    end

    assert_not ConstrainedRouteLink.exists?(first_link.id)
    assert ConstrainedRouteLink.exists?(second_link.id)
    assert_equal [second_link], post.route_links.to_a
  end

  def test_through_matching_uses_the_actual_destination_record_type
    post = ConstrainedRoutePost.create!(title: "Typed through", body: "Typed through")
    ship = StringKeyRouteShip.create!(pirate_id: 9_000_841, name: "String key ship")
    link = ConstrainedRouteLink.create!(sponsorable_id: post.id, club_id: ship.pirate_id)
    post.route_links.load

    assert_equal :integer, Ship.type_for_attribute("pirate_id").type
    assert_equal :string, ship.class.type_for_attribute("pirate_id").type

    post.route_ships.delete(ship)

    assert_not ConstrainedRouteLink.exists?(link.id)
    assert_empty post.route_links
  end

  def test_through_matching_uses_each_loaded_candidate_class
    string_link_class = Class.new(ConstrainedRouteLink) do
      def self.name = "StringThroughRouteLink"
      attribute :club_id, :string
    end
    post = ConstrainedRoutePost.create!(title: "Mixed through", body: "Mixed through")
    ship = Ship.create!(pirate_id: 9_000_842, name: "Mixed through ship")
    first = ConstrainedRouteLink.create!(sponsorable_id: post.id, club_id: ship.pirate_id)
    second = string_link_class.create!(sponsorable_id: post.id, club_id: ship.pirate_id)
    decoy = ConstrainedRouteLink.create!(sponsorable_id: post.id, club_id: ship.pirate_id + 1)
    post.association(:route_links).target = [first, second, decoy]

    assert_equal :integer, first.class.type_for_attribute("club_id").type
    assert_equal :string, second.class.type_for_attribute("club_id").type

    post.route_ships.delete(ship)

    assert_equal [decoy], post.route_links.to_a
    assert_not ConstrainedRouteLink.exists?(first.id)
    assert_not ConstrainedRouteLink.exists?(second.id)
    assert ConstrainedRouteLink.exists?(decoy.id)
  end

  def test_through_matching_preserves_component_comparison_across_key_shapes
    post = ConstrainedRoutePost.create!(title: "Through key shapes", body: "Through key shapes")
    ship = Ship.create!(pirate_id: 9_000_851, name: "Through key shapes")
    link = ConstrainedRouteLink.create!(sponsorable_id: post.id, club_id: ship.pirate_id)
    post.route_links.load
    reflection = ConstrainedRouteLink.reflect_on_association(:ship)

    [[:club_id, [:pirate_id]], [[:club_id], :pirate_id]].each do |reference_key, target_key|
      route = build_belongs_to_route(
        reference: { reference_key: reference_key, target_key: target_key },
        constraints: { reference_key: nil, target_key: nil }
      )
      reflection.stub(:association_route, route) do
        assert_equal [link], post.association(:route_ships).send(:through_records_for, ship)
      end
    end
  end

  def test_reference_metadata_does_not_resolve_a_missing_polymorphic_class
    reference_class = Class.new(ActiveRecord::Base) do
      self.table_name = "sponsors"

      def self.name = "MissingClassRoutedReference"

      belongs_to :routed_target,
        polymorphic: true,
        foreign_key: :sponsorable_id,
        foreign_type: :sponsorable_type,
        counter_cache: true,
        optional: true
    end
    reference_class.insert_all!([
      { club_id: 1, sponsorable_id: nil, sponsorable_type: "MissingNamespace::MissingRoutedClass" }
    ])
    reference = reference_class.find_by!(club_id: 1)
    association = reference.association(:routed_target)

    reference_class.stub(:polymorphic_class_for, ->(*) { flunk("foreign-key metadata resolved the polymorphic class") }) do
      assert_equal ActiveRecord::Key.for(:sponsorable_id), association.foreign_key
      assert_not_predicate association, :target_changed?
    end

    reference.club_id = 2
    assert_nothing_raised { reference.save! }
  end

  def test_polymorphic_reference_can_be_cleared_when_stored_class_is_missing
    sponsor = Sponsor.new(sponsorable_id: 42, sponsorable_type: "MissingNamespace::MissingRoutedClass")

    assert_nothing_raised { sponsor.sponsorable = nil }
    assert_nil sponsor.sponsorable_id
    assert_nil sponsor.sponsorable_type
  end

  private
    def fresh_route_reflections
      [
        [ActiveRecord::Reflection.create(:belongs_to, :firm, nil,
          { class_name: "Firm", foreign_key: :client_of, inverse_of: false }, Client), Firm],
        [ActiveRecord::Reflection.create(:has_one, :sponsor, nil,
          { class_name: "Sponsor", as: :sponsorable, inverse_of: false }, Member), Sponsor],
        [ActiveRecord::Reflection.create(:belongs_to, :sponsorable, nil,
          { polymorphic: true, inverse_of: false }, Sponsor), Member],
      ]
    end

    def assert_touch_preserves_singleton_reference(old_value)
      original = TouchRouteBook.create!(boolean_status: old_value)
      replacement = TouchRouteBook.create!(boolean_status: true)
      reference = SingletonTouchRouteReference.create!(name: "Touch route reference", boolean_status: old_value)
      original_time = Time.utc(2000, 1, 1)
      original.update_column(:updated_at, original_time)
      replacement.update_column(:updated_at, original_time)

      reference.update!(boolean_status: true)

      assert_operator original.reload.updated_at, :>, original_time
      assert_operator replacement.reload.updated_at, :>, original_time
    end

    def each_statement_mode(&)
      yield
      ActiveRecord::Base.lease_connection.unprepared_statement(&)
    end

    def build_mapping(reference_key:, target_key:)
      ActiveRecord::Key::Mapping.new(
        reference_key: ActiveRecord::Key.for(reference_key),
        target_key: ActiveRecord::Key.for(target_key)
      )
    end

    def with_constraints(reflection, reference_key:, target_key:, &block)
      constraints = build_mapping(reference_key: reference_key, target_key: target_key)
      reflection.clear_association_scope_cache unless reflection.polymorphic?
      reflection.stub(:association_route_constraints, constraints, &block)
    ensure
      reflection.clear_association_scope_cache unless reflection.polymorphic?
    end

    def build_belongs_to_route(reference:, constraints:)
      reference = build_mapping(**reference)
      constraints = build_mapping(**constraints)

      ActiveRecord::AssociationRoute.new(link: ActiveRecord::AssociationLink.new(reference: reference, constraints: constraints))
    end

    def build_route(reference:, constraints:)
      reference = build_mapping(**reference)
      constraints = build_mapping(**constraints)

      ActiveRecord::AssociationRoute::Reverse.new(link: ActiveRecord::AssociationLink.new(reference: reference, constraints: constraints))
    end
end
