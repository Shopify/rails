# frozen_string_literal: true

require "cases/helper"
require "tempfile"

module ActiveRecord
  module AttributeMethods
    class LinkerTest < ActiveRecord::TestCase
      self.use_transactional_tests = false

      teardown do
        ActiveRecord.attribute_methods_link_path = nil
        @link_file&.close!
      end

      test "linked models receive the same methods as generated models" do
        link record(model("Topic", "topics"))

        linked = model("Topic", "topics")
        generated = model("Topic", "topics")

        assert_linked linked
        generated.define_attribute_methods

        assert_equal method_table(generated), method_table(linked)
      end

      test "linked attribute methods read, write and track changes" do
        link record(model("Topic", "topics"))
        topic_class = model("Topic", "topics")
        assert_linked topic_class

        topic = topic_class.new(title: "Linked")
        assert_equal "Linked", topic.title
        assert_predicate topic, :title?
        topic.title = "Changed"
        assert_equal "Changed", topic.title
        assert_equal [nil, "Changed"], topic.title_change
        assert_predicate topic, :title_changed?
      end

      test "aliases are part of the recorded methods" do
        link record(model("Topic", "topics") { alias_attribute :heading, :title })
        topic_class = model("Topic", "topics") { alias_attribute :heading, :title }
        assert_linked topic_class

        topic = topic_class.new(title: "Linked")
        assert_equal "Linked", topic.heading
        assert_predicate topic, :heading_changed?
      end

      test "a model whose aliases changed since recording generates its methods" do
        link record(model("Topic", "topics"))
        topic_class = model("Topic", "topics") { alias_attribute :heading, :title }

        assert_not_linked topic_class
        assert_equal "Generated", topic_class.new(title: "Generated").heading
      end

      test "a model whose attribute names changed since recording generates its methods" do
        link record(model("Topic", "topics"))
        topic_class = model("Topic", "topics") { self.ignored_columns += ["title"] }

        assert_not_linked topic_class
        assert_not topic_class.method_defined?(:title)
      end

      test "a model without an entry generates its methods" do
        link record(model("Topic", "topics"))

        assert_not_linked model("Reply", "topics")
      end

      test "a link file from another version of Rails is ignored" do
        source = record(model("Topic", "topics"))
        link source.sub(ActiveRecord.version.to_s.inspect, "0.0.1".inspect)

        assert_not_linked model("Topic", "topics")
      end

      test "an entry is used once, so methods defined again after a reset are generated" do
        link record(model("Topic", "topics"))
        topic_class = model("Topic", "topics")
        assert_linked topic_class

        topic_class.reset_column_information
        assert_not_linked topic_class
        assert_equal "Generated", topic_class.new(title: "Generated").title
      end

      test "columns whose names are not method names keep their attribute name constants" do
        source = record(model("Weird", "weirds"))
        constant = :"ATTR_#{"a$b".unpack1("h*")}"
        ActiveModel::AttributeMethods::AttrNames.send(:remove_const, constant)

        link source
        weird_class = model("Weird", "weirds")
        assert_linked weird_class

        assert_equal "a$b", ActiveModel::AttributeMethods::AttrNames.const_get(constant)
        assert_equal "linked", weird_class.new("a$b": "linked").public_send(:"a$b")
      end

      test "methods defined before recording started are not recorded" do
        topic_class = model("Topic", "topics")
        topic_class.define_attribute_methods

        recording = Linker.record { topic_class.define_attribute_methods }

        assert_empty recording.models
      end

      private
        def model(name, table_name, &block)
          Class.new(ActiveRecord::Base) do
            define_singleton_method(:name) { "ActiveRecord::AttributeMethods::LinkerTest::#{name}" }
            self.table_name = table_name
            class_eval(&block) if block
          end
        end

        def record(model)
          recording = Linker.record { model.define_attribute_methods }
          assert_equal [model], recording.models
          recording.source
        end

        def link(source)
          @link_file = Tempfile.new(["attribute_methods_link", ".rb"])
          @link_file.write(source)
          @link_file.flush
          ActiveRecord.attribute_methods_link_path = @link_file.path
        end

        def assert_linked(model)
          assert_equal 0, generated_attribute_count(model), "#{model.name} generated its attribute methods"
          assert model.method_defined?(:id), "#{model.name} has no attribute methods"
        end

        def assert_not_linked(model)
          assert_operator generated_attribute_count(model), :>, 0, "#{model.name} bound recorded attribute methods"
        end

        def generated_attribute_count(model)
          count = 0
          model.singleton_class.prepend(Module.new do
            define_method(:define_attribute_method) do |*arguments, **options|
              count += 1
              super(*arguments, **options)
            end
          end)
          model.define_attribute_methods
          count
        end

        def method_table(model)
          mod = model.send(:generated_attribute_methods)
          (mod.instance_methods(false) + mod.private_instance_methods(false)).sort.map do |name|
            method = mod.instance_method(name)
            [name, method.original_name, method.parameters, mod.public_method_defined?(name)]
          end
        end
    end
  end
end
