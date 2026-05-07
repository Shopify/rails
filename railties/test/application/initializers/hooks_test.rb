# frozen_string_literal: true

require "isolation/abstract_unit"

module ApplicationTests
  class HooksTest < ActiveSupport::TestCase
    include ActiveSupport::Testing::Isolation

    def setup
      build_app
      FileUtils.rm_rf "#{app_path}/config/environments"
    end

    def teardown
      teardown_app
    end

    test "load initializers" do
      app_file "config/initializers/foo.rb", "$foo = true"
      require "#{app_path}/config/environment"
      assert $foo
    end

    test "hooks block works correctly without eager_load (before_eager_load is not called)" do
      add_to_config <<-RUBY
        $initialization_callbacks = []
        config.root = "#{app_path}"
        config.eager_load = false
        config.before_configuration { $initialization_callbacks << 1 }
        config.before_initialize    { $initialization_callbacks << 2 }
        config.before_eager_load    { Boom }
        config.after_initialize     { $initialization_callbacks << 3 }
      RUBY

      require "#{app_path}/config/environment"
      assert_equal [1, 2, 3], $initialization_callbacks
    end

    test "hooks block works correctly with eager_load" do
      add_to_config <<-RUBY
        $initialization_callbacks = []
        config.root = "#{app_path}"
        config.eager_load = true
        config.before_configuration { $initialization_callbacks << 1 }
        config.before_initialize    { $initialization_callbacks << 2 }
        config.before_eager_load    { $initialization_callbacks << 3 }
        config.after_initialize     { $initialization_callbacks << 4 }
      RUBY

      require "#{app_path}/config/environment"
      assert_equal [1, 2, 3, 4], $initialization_callbacks
    end

    test "before_sharing does not run by default" do
      $before_sharing = false
      add_to_config <<-RUBY
        config.before_sharing { $before_sharing = true }
      RUBY

      require "#{app_path}/config/environment"
      assert_equal false, Rails.application.config.enable_ractorization
      assert_not $before_sharing
      assert_not_predicate Rails.application, :ractorized?
    end

    test "ractorization requires eager loading" do
      $before_sharing = false
      add_to_config <<-RUBY
        config.eager_load = false
        config.enable_ractorization = true
        config.before_sharing { $before_sharing = true }
      RUBY

      error = assert_raises(RuntimeError) do
        require "#{app_path}/config/environment"
      end

      assert_equal "Ractorization requires config.eager_load to be true.", error.message
      assert_not $before_sharing
      assert_not_predicate Rails.application, :ractorized?
    end

    test "before_sharing runs after after_initialize when ractorization is enabled" do
      $order = []
      add_to_config <<-RUBY
        config.eager_load = true
        config.enable_ractorization = true
        config.after_initialize { $order << :after_initialize }
        config.before_sharing { |app| $order << [:before_sharing, app.equal?(Rails.application), app.initialized?] }
      RUBY

      require "#{app_path}/config/environment"
      assert_equal [:after_initialize, [:before_sharing, true, true]], $order
      assert_predicate Rails.application, :ractorized?
    end

    test "ractorize runs before_sharing hooks once" do
      $before_sharing_count = 0
      $before_sharing_application = nil
      add_to_config <<-RUBY
        config.eager_load = true
        config.before_sharing do |app|
          $before_sharing_count += 1
          $before_sharing_application = app
        end
      RUBY

      require "#{app_path}/config/environment"
      Rails.application.ractorize!
      Rails.application.ractorize!

      assert_equal 1, $before_sharing_count
      assert_same Rails.application, $before_sharing_application
      assert_predicate Rails.application, :ractorized?
    end

    test "after_initialize runs after frameworks have been initialized" do
      $activerecord_configuration = nil
      add_to_config <<-RUBY
        config.after_initialize { $activerecord_configuration = ActiveRecord::Base.configurations.configs_for(env_name: "development", name: "primary") }
      RUBY

      require "#{app_path}/config/environment"
      assert $activerecord_configuration
    end

    test "after_initialize happens after to_prepare in development" do
      $order = []
      add_to_config <<-RUBY
        config.enable_reloading = true
        config.after_initialize { $order << :after_initialize }
        config.to_prepare { $order << :to_prepare }
      RUBY

      require "#{app_path}/config/environment"
      assert_equal [:to_prepare, :after_initialize], $order
    end

    test "after_initialize happens after to_prepare in production" do
      $order = []
      add_to_config <<-RUBY
        config.enable_reloading = false
        config.after_initialize { $order << :after_initialize }
        config.to_prepare { $order << :to_prepare }
      RUBY

      require "#{app_path}/config/application"
      Rails.env.replace "production"
      require "#{app_path}/config/environment"
      assert_equal [:to_prepare, :after_initialize], $order
    end
  end
end
