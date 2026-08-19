# frozen_string_literal: true

require "cases/helper"
require "models/post"
require "models/comment"

class AssociationVariantsTest < ActiveRecord::TestCase
  fixtures :posts, :comments

  # Both variants point at comments, but through different columns on both sides,
  # so they select disjoint sets of records for the same owner.
  class VariantPost < ActiveRecord::Base
    self.table_name = "posts"
    self.inheritance_column = nil

    singleton_class.attr_accessor :variant

    has_many_with_variants :variant_comments, class_name: "Comment", dependent: :delete_all,
      variants: {
        by_post: { foreign_key: :post_id },
        by_author: { foreign_key: :author_id, primary_key: :author_id },
      } do
        VariantPost.variant
      end
  end

  # Both variants share a foreign key; only the extra read constraint differs.
  class ConstrainedVariantPost < ActiveRecord::Base
    self.table_name = "posts"
    self.inheritance_column = nil

    singleton_class.attr_accessor :variant

    has_many_with_variants :variant_comments, class_name: "Comment",
      variants: {
        all: { foreign_key: :post_id },
        matching_title: { foreign_key: :post_id, query_constraints: { title: :body } },
      } do
        ConstrainedVariantPost.variant
      end

    # The same options declared without variants, to compare against.
    has_many :matching_title_comments, class_name: "Comment", foreign_key: :post_id,
      query_constraints: { title: :body }
  end

  # Selects a variant from the owner rather than from global state, and records the
  # records it was asked about.
  class PerOwnerVariantPost < ActiveRecord::Base
    self.table_name = "posts"
    self.inheritance_column = nil

    singleton_class.attr_accessor :selected_for

    has_many_with_variants :variant_comments, class_name: "Comment",
      variants: {
        by_post: { foreign_key: :post_id },
        by_author: { foreign_key: :author_id, primary_key: :author_id },
      } do |post|
        PerOwnerVariantPost.selected_for << post.id
        post.id == 1 ? :by_post : :by_author
      end
  end

  setup do
    VariantPost.variant = :by_post
    ConstrainedVariantPost.variant = :all
    PerOwnerVariantPost.selected_for = []
  end

  def test_the_selected_variant_determines_the_loaded_target
    post = VariantPost.find(1)
    by_post = Comment.create!(post_id: post.id, body: "Of this post")
    by_author = Comment.create!(post_id: 2, author_id: post.author_id, body: "By this author")

    assert_includes post.variant_comments, by_post
    assert_not_includes post.variant_comments, by_author

    VariantPost.variant = :by_author

    assert_includes post.variant_comments, by_author
    assert_not_includes post.variant_comments, by_post
  end

  def test_switching_variants_makes_a_loaded_target_stale
    post = VariantPost.find(1)
    post.variant_comments.load

    assert_predicate post.association(:variant_comments), :loaded?
    assert_not_predicate post.association(:variant_comments), :stale_target?

    VariantPost.variant = :by_author

    assert_predicate post.association(:variant_comments), :stale_target?
  end

  def test_reading_a_stale_variant_association_reloads_it_without_an_explicit_reset
    post = VariantPost.find(1)
    post.variant_comments.load

    VariantPost.variant = :by_author

    assert_queries_match(/"comments"\."author_id"/, count: 1) do
      post.variant_comments.to_a
    end
  end

  def test_returning_to_a_previously_loaded_variant_reloads_it
    post = VariantPost.find(1)
    by_post = Comment.create!(post_id: post.id, body: "Of this post")

    assert_includes post.variant_comments, by_post

    VariantPost.variant = :by_author
    post.variant_comments.to_a
    VariantPost.variant = :by_post

    assert_includes post.variant_comments, by_post
  end

  def test_build_writes_the_keys_of_the_selected_variant
    post = VariantPost.find(1)

    built = post.variant_comments.build
    assert_equal post.id, built.post_id
    assert_nil built.author_id

    VariantPost.variant = :by_author

    built = post.variant_comments.build
    assert_equal post.author_id, built.author_id
  end

  def test_options_shared_by_every_variant_still_generate_callbacks
    post = VariantPost.create!(title: "Title", body: "Body", author_id: 1)
    comment = Comment.create!(post_id: post.id, body: "Deleted along with the post")

    post.destroy

    assert_not_predicate Comment.where(id: comment.id), :exists?
  end

  def test_query_constraints_can_differ_between_variants
    post = ConstrainedVariantPost.find(1)
    matching = Comment.create!(post_id: post.id, body: post.title)
    mismatching = Comment.create!(post_id: post.id, body: "Not the title")

    assert_includes post.variant_comments, matching
    assert_includes post.variant_comments, mismatching

    ConstrainedVariantPost.variant = :matching_title

    assert_includes post.variant_comments, matching
    assert_not_includes post.variant_comments, mismatching
  end

  def test_a_variant_assigns_what_the_same_options_would_assign_without_variants
    ConstrainedVariantPost.variant = :matching_title
    post = ConstrainedVariantPost.find(1)

    assert_equal post.matching_title_comments.build.attributes,
      post.variant_comments.build.attributes
  end

  def test_each_variant_prepares_its_own_statement
    first, second = VariantPost.find(1), VariantPost.find(2)

    by_post = capture_sql { first.variant_comments.to_a }
    assert_equal 1, by_post.size
    assert_match(/"comments"\."post_id"/, by_post.first)

    # Same variant, another owner: the same query shape, so one cached statement
    # serves every record.
    assert_equal by_post, capture_sql { second.variant_comments.to_a }

    VariantPost.variant = :by_author
    by_author = capture_sql { first.variant_comments.to_a }

    # A different variant must not be served the statement cached for the first one.
    assert_match(/"comments"\."author_id"/, by_author.first)
    assert_not_equal by_post, by_author
  end

  def test_the_selector_runs_against_each_owner_record
    one, other = PerOwnerVariantPost.find(1), PerOwnerVariantPost.find(7)

    assert_equal :by_post, one.association(:variant_comments).reflection.variant_name
    assert_equal :by_author, other.association(:variant_comments).reflection.variant_name
    assert_equal [1, 7], PerOwnerVariantPost.selected_for.uniq.sort
  end

  def test_two_owners_can_have_different_variants_selected_at_once
    one, other = PerOwnerVariantPost.find(1), PerOwnerVariantPost.find(7)
    assert_not_equal one.author_id, other.author_id

    by_post = Comment.create!(post_id: one.id, body: "Of post one")
    by_author = Comment.create!(post_id: 3, author_id: other.author_id, body: "By the other author")

    assert_includes one.variant_comments, by_post
    assert_not_includes one.variant_comments, by_author
    assert_includes other.variant_comments, by_author
    assert_not_includes other.variant_comments, by_post
  end

  def test_a_variant_association_survives_a_marshal_round_trip
    post = VariantPost.find(1)
    Comment.create!(post_id: post.id, body: "Of this post")
    post.variant_comments.load

    loaded = Marshal.load(Marshal.dump(post))

    assert_equal post.variant_comments.map(&:id), loaded.variant_comments.map(&:id)

    VariantPost.variant = :by_author

    assert_predicate loaded.association(:variant_comments), :stale_target?
  end

  # Every path below resolves the association from the class, where there is no owner
  # record to select a variant with.

  def test_preloading_a_variant_association_raises
    error = assert_raises(ActiveRecord::AssociationVariantNotSupported) do
      VariantPost.preload(:variant_comments).to_a
    end

    assert_match "Cannot preload :variant_comments", error.message
  end

  def test_eager_loading_a_variant_association_raises
    error = assert_raises(ActiveRecord::AssociationVariantNotSupported) do
      VariantPost.eager_load(:variant_comments).to_a
    end

    assert_match "Cannot join :variant_comments", error.message
  end

  def test_joining_a_variant_association_raises
    assert_raises(ActiveRecord::AssociationVariantNotSupported) do
      VariantPost.joins(:variant_comments).to_a
    end
  end

  def test_including_a_variant_association_raises
    assert_raises(ActiveRecord::AssociationVariantNotSupported) do
      VariantPost.includes(:variant_comments).to_a
    end
  end

  def test_variants_require_a_selector
    error = assert_raises(ArgumentError) do
      variant_post_class { has_many_with_variants :variant_comments, variants: { by_post: {} } }
    end

    assert_match "requires a block returning the name of the active variant", error.message
  end

  def test_variants_require_at_least_one_variant
    error = assert_raises(ArgumentError) do
      variant_post_class { has_many_with_variants(:variant_comments, variants: {}) { :by_post } }
    end

    assert_match "requires a `variants:` Hash naming at least one variant", error.message
  end

  def test_variants_cannot_be_combined_with_through
    error = assert_raises(ArgumentError) do
      variant_post_class do
        has_many_with_variants(:variant_comments, through: :author, variants: { by_post: {} }) { :by_post }
      end
    end

    assert_match "cannot combine `:through` with `variants:`", error.message
  end

  def test_variants_may_only_differ_in_the_columns_they_are_keyed_on
    error = assert_raises(ArgumentError) do
      variant_post_class do
        has_many_with_variants(:variant_comments, class_name: "Comment", variants: {
          by_post: { foreign_key: :post_id, dependent: :destroy },
          by_author: { foreign_key: :author_id },
        }) { :by_post }
      end
    end

    assert_match ":dependent cannot differ between the variants", error.message
    assert_match "Declare it on the association itself", error.message
  end

  def test_an_unknown_option_in_a_variant_is_rejected_when_the_association_is_declared
    error = assert_raises(ArgumentError) do
      variant_post_class do
        has_many_with_variants(:variant_comments, variants: { by_post: { foreign_kye: :post_id } }) { :by_post }
      end
    end

    assert_match ":foreign_kye cannot differ between the variants", error.message
  end

  # Each variant is validated like any other association: on first use, and only the
  # variant being used.
  def test_a_variant_whose_options_do_not_add_up_is_rejected_when_it_is_selected
    selected = :by_post
    post_class = variant_post_class do
      has_many_with_variants(:variant_comments, class_name: "Comment", variants: {
        by_post: { foreign_key: :post_id },
        broken: { foreign_key: :author_id, query_constraints: :author_id },
      }) { selected }
    end
    post = post_class.find(1)

    assert_nothing_raised { post.variant_comments.to_a }

    selected = :broken
    error = assert_raises(ArgumentError) { post_class.find(1).variant_comments.to_a }

    assert_match "`query_constraints`", error.message
    assert_match "must not include the foreign key columns", error.message
  end

  def test_variant_names_must_be_symbols
    error = assert_raises(ArgumentError) do
      variant_post_class { has_many_with_variants(:variant_comments, variants: { "by_post" => {} }) { :by_post } }
    end

    assert_match 'must be Symbols, got "by_post"', error.message
  end

  def test_variant_options_must_be_hashes
    error = assert_raises(ArgumentError) do
      variant_post_class { has_many_with_variants(:variant_comments, variants: { by_post: :post_id }) { :by_post } }
    end

    assert_match "Options for variant :by_post", error.message
  end

  private
    # Declaring a variant association can fail, so the class is thrown away rather
    # than kept around as a constant.
    def variant_post_class(&declaration)
      Class.new(ActiveRecord::Base) do
        def self.name
          "MisdeclaredVariantPost"
        end

        self.table_name = "posts"
        self.inheritance_column = nil

        class_eval(&declaration)
      end
    end
end
