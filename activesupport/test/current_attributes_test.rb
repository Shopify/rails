# frozen_string_literal: true

require_relative "abstract_unit"
require "active_support/current_attributes/test_helper"

class CurrentAttributesTest < ActiveSupport::TestCase
  # CurrentAttributes is automatically reset in Rails app via executor hooks set in railtie
  # But not in Active Support's own test suite.
  include ActiveSupport::CurrentAttributes::TestHelper

  Person = Struct.new(:id, :name, :time_zone)

  class Current < ActiveSupport::CurrentAttributes
    attribute :world, :account, :person, :request
    delegate :time_zone, to: :person

    before_reset { Session.previous = person&.id }

    resets do
      Session.current = nil
    end

    resets :clear_time_zone

    def account=(account)
      super
      self.person = Person.new(1, "#{account}'s person")
    end

    def person=(person)
      super
      Time.zone = person&.time_zone
      Session.current = person&.id
    end

    def set_world_and_account(world:, account:)
      self.world = world
      self.account = account
    end

    def get_world_and_account(hash)
      hash[:world] = world
      hash[:account] = account
      hash
    end

    def respond_to_test; end

    def request
      "#{super} something"
    end

    def intro
      "#{person.name}, in #{time_zone}"
    end

    private
      def clear_time_zone
        Time.zone = "UTC"
      end
  end

  class Session < ActiveSupport::CurrentAttributes
    attribute :current, :previous
  end

  # Eagerly set-up `instance`s by reference.
  [ Current.instance, Session.instance ]

  # Use library specific minitest hook to catch Time.zone before reset is called via TestHelper
  def before_setup
    @original_time_zone = Time.zone
    super
  end

  # Use library specific minitest hook to set Time.zone after reset is called via TestHelper
  def after_teardown
    super
    Time.zone = @original_time_zone
  end

  setup { assert_nil Session.previous, "Expected Session to not have leaked state" }

  setup { @testing_teardown = false }
  teardown { assert_equal 42, Session.current if @testing_teardown }

  test "accessing attributes in teardown" do
    Session.current = 42
    @testing_teardown = true
  end

  test "delegation" do
    Current.person = Person.new(42, "David", "Central Time (US & Canada)")
    assert_equal "Central Time (US & Canada)", Current.time_zone
    assert_equal "Central Time (US & Canada)", Current.instance.time_zone
  end

  test "all methods forward to the instance" do
    Current.person = Person.new(42, "David", "Central Time (US & Canada)")
    assert_equal "David, in Central Time (US & Canada)", Current.intro
    assert_equal "David, in Central Time (US & Canada)", Current.instance.intro
  end

  test "CurrentAttributes use fiber-local variables" do
    previous_level = ActiveSupport::IsolatedExecutionState.isolation_level
    ActiveSupport::IsolatedExecutionState.isolation_level = :fiber

    Session.current = 42
    enumerator = Enumerator.new do |yielder|
      yielder.yield Session.current
    end
    assert_nil enumerator.next
  ensure
    ActiveSupport::IsolatedExecutionState.isolation_level = previous_level
  end

  test "CurrentAttributes can use thread-local variables" do
    previous_level = ActiveSupport::IsolatedExecutionState.isolation_level
    ActiveSupport::IsolatedExecutionState.isolation_level = :thread

    Session.current = 42
    enumerator = Enumerator.new do |yielder|
      yielder.yield Session.current
    end
    assert_equal 42, enumerator.next
  ensure
    ActiveSupport::IsolatedExecutionState.isolation_level = previous_level
  end

  test "CurrentAttributes restricted attribute names" do
    assert_raises ArgumentError, match: /Restricted attribute names: reset, set/ do
      class InvalidAttributeNames < ActiveSupport::CurrentAttributes
        attribute :reset, :foo, :set
      end
    end
  end
end
