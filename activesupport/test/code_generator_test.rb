# frozen_string_literal: true

require_relative "abstract_unit"

class CodeGeneratorTest < ActiveSupport::TestCase
  test "recording captures each cached method's source and the methods each owner received" do
    owner = Module.new

    recorder = ActiveSupport::CodeGenerator.record do
      ActiveSupport::CodeGenerator.batch(owner, __FILE__, __LINE__) do |generator|
        generator.define_cached_method(:recorded_greeting, namespace: :code_generator_test, as: :hello) do |batch|
          batch << "def recorded_greeting" << "'hello'" << "end"
        end
      end
    end

    assert_equal "def recorded_greeting\n'hello'\nend", recorder.sources[:code_generator_test][:recorded_greeting]
    assert_equal [[:code_generator_test, :hello, :recorded_greeting]], recorder.take_methods(owner)
    assert_empty recorder.take_methods(owner)
    assert_equal "hello", Object.new.extend(owner).hello
  end

  test "recording compiles into its own caches, so methods compiled earlier are captured again" do
    ActiveSupport::CodeGenerator.batch(Module.new, __FILE__, __LINE__) do |generator|
      generator.define_cached_method(:recorded_twice, namespace: :code_generator_test) do |batch|
        batch << "def recorded_twice" << "true" << "end"
      end
    end

    recorder = ActiveSupport::CodeGenerator.record do
      ActiveSupport::CodeGenerator.batch(Module.new, __FILE__, __LINE__) do |generator|
        generator.define_cached_method(:recorded_twice, namespace: :code_generator_test) do |batch|
          batch << "def recorded_twice" << "true" << "end"
        end
      end
    end

    assert_equal "def recorded_twice\ntrue\nend", recorder.sources[:code_generator_test][:recorded_twice]
    assert_not_same ActiveSupport::CodeGenerator::MethodSet::METHOD_CACHES[:code_generator_test], recorder.cache(:code_generator_test)
  end

  test "batches outside a recording are not recorded" do
    recorder = ActiveSupport::CodeGenerator.record { }

    assert_nil ActiveSupport::CodeGenerator.recorder
    assert_empty recorder.sources
  end
end
