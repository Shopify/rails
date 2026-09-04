# frozen_string_literal: true

require "cases/helper"
require "models/comment"
require "models/post"
require "models/ship"

class AssociationLinkTest < ActiveRecord::TestCase
  fixtures :posts

  def test_match_combines_constraints_and_reference
    constraints = ActiveRecord::Key::Mapping.new(reference_key: :tenant_id, target_key: :account_id)
    reference = ActiveRecord::Key::Mapping.new(reference_key: :author_id, target_key: :id)
    link = ActiveRecord::AssociationLink.new(reference: reference, constraints: constraints)

    assert_equal [["tenant_id", "account_id"], ["author_id", "id"]], link.match.to_a
  end

  def test_write_reference_copies_only_reference_values
    reference = ActiveRecord::Key::Mapping.new(reference_key: :author_id, target_key: :id)
    constraints = ActiveRecord::Key::Mapping.new(reference_key: :tenant_id, target_key: :tenant_id)
    link = ActiveRecord::AssociationLink.new(reference: reference, constraints: constraints)
    source = Struct.new(:attributes) do
      def read_attribute(name)
        attributes[name]
      end

      def write_attribute(name, value)
        attributes[name] = value
      end
    end
    reference_record = source.new({ "author_id" => nil, "tenant_id" => 1 })
    target_record = source.new({ "id" => 7, "tenant_id" => 2 })

    link.write_reference(reference_record, target_record)

    assert_equal({ "author_id" => 7, "tenant_id" => 1 }, reference_record.attributes)
  end

  def test_query_consumers_use_match_and_write_consumers_use_reference
    reflection = Post.reflect_on_association(:comments)
    inverse_reflection = Comment.reflect_on_association(:post)
    link = build_link(
      reference: { reference_key: :post_id, target_key: :id },
      constraints: { reference_key: :body, target_key: :title }
    )
    post = posts(:welcome)
    matching = Comment.create!(post_id: post.id, body: post.title)
    mismatching = Comment.create!(post_id: post.id, body: "Not the post title")

    reflection.stub(:association_link, ->(*) { link }) do
      inverse_reflection.stub(:association_link, ->(*) { link }) do
        assert_equal [matching], post.comments.where(id: [matching.id, mismatching.id]).to_a

        built = post.comments.build
        assert_equal post.id, built.post_id
        assert_nil built.body

        preloaded = Post.where(id: post.id).preload(:comments).first
        assert_includes preloaded.comments, matching
        assert_not_includes preloaded.comments, mismatching

        matching_join = Post.joins(:comments).where(posts: { id: post.id }, comments: { id: matching.id })
        mismatching_join = Post.joins(:comments).where(posts: { id: post.id }, comments: { id: mismatching.id })
        assert_predicate matching_join, :exists?
        assert_not_predicate mismatching_join, :exists?
        assert_equal [matching], Comment.where(post: post).where(id: [matching.id, mismatching.id]).to_a
      end
    end
  end

  def test_query_constraints_identify_counter_cache_destinations
    reference_class = Class.new(ActiveRecord::Base) do
      self.table_name = "comments"
      self.inheritance_column = nil

      def self.name = "ConstrainedLinkCounterReference"

      belongs_to :linked_post,
        class_name: "Post",
        foreign_key: :post_id,
        counter_cache: :legacy_comments_count,
        optional: true
    end
    reflection = reference_class.reflect_on_association(:linked_post)
    link = build_link(
      reference: { reference_key: :author_id, target_key: :author_id },
      constraints: { reference_key: :body, target_key: :title }
    )
    old_post = Post.create!(author_id: 9_000_101, title: "Old linked post", body: "Old")
    decoy = Post.create!(author_id: old_post.author_id, title: "Decoy linked post", body: "Decoy")
    new_post = Post.create!(author_id: 9_000_102, title: "New linked post", body: "New")
    old_post.update_column(:legacy_comments_count, 1)
    decoy.update_column(:legacy_comments_count, 1)
    reference_class.insert_all!([{ post_id: -1, author_id: old_post.author_id, body: old_post.title }])
    reference = reference_class.find_by!(body: old_post.title)

    reflection.stub(:association_link, ->(*) { link }) do
      reference.author_id = new_post.author_id
      reference.body = new_post.title
      reference.save!
    end

    assert_equal 0, old_post.reload.legacy_comments_count
    assert_equal 1, decoy.reload.legacy_comments_count
    assert_equal 1, new_post.reload.legacy_comments_count
  end

  def test_query_constraints_identify_touch_destinations
    reference_class = Class.new(ActiveRecord::Base) do
      self.table_name = "sponsors"

      def self.name = "ConstrainedLinkTouchReference"

      belongs_to :linked_ship,
        class_name: "Ship",
        foreign_key: :sponsorable_id,
        touch: true,
        optional: true
    end
    reflection = reference_class.reflect_on_association(:linked_ship)
    link = build_link(
      reference: { reference_key: :club_id, target_key: :pirate_id },
      constraints: { reference_key: :sponsorable_type, target_key: :name }
    )
    original_time = Time.utc(2000)
    decoy = Ship.create!(name: "Decoy linked ship", pirate_id: 9_000_111, updated_at: original_time)
    old_ship = Ship.create!(name: "Old linked ship", pirate_id: decoy.pirate_id, updated_at: original_time)
    new_ship = Ship.create!(name: "New linked ship", pirate_id: 9_000_112, updated_at: original_time)
    reference = reference_class.create!(
      club_id: old_ship.pirate_id,
      sponsorable_id: -1,
      sponsorable_type: old_ship.name
    )

    reflection.stub(:association_link, ->(*) { link }) do
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

      def self.name = "ConstrainedLinkAsyncReference"

      belongs_to :linked_post,
        class_name: "Post",
        foreign_key: :post_id,
        optional: true
    end
    reflection = reference_class.reflect_on_association(:linked_post)
    reflection.options[:dependent] = :destroy_async
    link = build_link(
      reference: { reference_key: :author_id, target_key: :author_id },
      constraints: { reference_key: :body, target_key: :title }
    )
    post = Post.create!(author_id: 9_000_121, title: "Async linked post", body: "Async")
    reference = reference_class.create!(post_id: -1, author_id: post.author_id, body: post.title)
    association = reference.association(:linked_post)
    enqueued = nil

    reflection.stub(:association_link, ->(*) { link }) do
      association.stub(:enqueue_destroy_association, ->(**options) { enqueued = options }) do
        association.handle_dependency
      end
    end

    assert_equal Post.to_s, enqueued[:association_class]
    assert_equal [[post.title, post.author_id]], enqueued[:association_ids]
    assert_equal ["title", "author_id"], enqueued[:association_primary_key_column]
  end

  private
    def build_link(reference:, constraints:)
      ActiveRecord::AssociationLink.new(
        reference: ActiveRecord::Key::Mapping.new(**reference),
        constraints: ActiveRecord::Key::Mapping.new(**constraints)
      )
    end
end
