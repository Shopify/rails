# frozen_string_literal: true

require "isolation/abstract_unit"

module Rails
  class Engine
    class LazyRouteSetTest < ActiveSupport::TestCase
      include ActiveSupport::Testing::Isolation

      setup :build_app

      teardown :teardown_app

      test "app lazily loads routes when invoking url helpers" do
        require "#{app_path}/config/environment"

        assert_not_operator(:root_path, :in?, app_url_helpers.methods)
        assert_equal("/", app_url_helpers.root_path)
      end

      test "engine lazily loads routes when invoking url helpers" do
        require "#{app_path}/config/environment"

        assert_not_operator(:root_path, :in?, engine_url_helpers.methods)
        assert_equal("/plugin/", engine_url_helpers.root_path)
      end

      test "app lazily loads routes when checking respond_to?" do
        require "#{app_path}/config/environment"

        assert_not_operator(:root_path, :in?, app_url_helpers.methods)
        assert_operator(app_url_helpers, :respond_to?, :root_path)
      end

      test "engine lazily loads routes when checking respond_to?" do
        require "#{app_path}/config/environment"

        assert_not_operator(:root_path, :in?, engine_url_helpers.methods)
        assert_operator(engine_url_helpers, :respond_to?, :root_path)
      end

      test "app lazily loads routes when making a request" do
        require "#{app_path}/config/environment"

        @app = Rails.application

        assert_not_operator(:root_path, :in?, app_url_helpers.methods)
        response = get("/")
        assert_equal(200, response.first)
      end

      test "engine lazily loads routes when making a request" do
        require "#{app_path}/config/environment"

        @app = Rails.application

        assert_not_operator(:root_path, :in?, engine_url_helpers.methods)
        response = get("/plugin/")
        assert_equal(200, response.first)
      end

      test "app lazily loads routes when url_for is used" do
        assert_not_operator(:users_path, :in?, app_url_helpers.methods)

        assert_equal "/users", Rails.application.route_set.url_helpers.url_for(User)
      end

      test "engine lazily loads routes when url_for is used" do
        assert_not_operator(:blogs_path, :in?, engine_url_helpers.methods)

        assert_equal "/plugin/posts", Rails.application.route_set.url_helpers.url_for(Post)
      end

      private
        def build_app
          super

          app_file "app/models/user.rb", <<~RUBY
            class User < ActiveRecord::Base
            end
          RUBY

          app_file "config/routes.rb", <<~RUBY
            Rails.application.routes.draw do
              root to: proc { [200, {}, []] }

              resources(:users)

              mount Plugin::Engine, at: "/plugin"
            end
          RUBY

          build_engine
        end

        def build_engine
          engine "plugin" do |plugin|
            plugin.write "app/models/post.rb", <<~RUBY
              class Post < ActiveRecord::Base
              end
            RUBY

            plugin.write "lib/plugin.rb", <<~RUBY
              module Plugin
                class Engine < ::Rails::Engine
                end
              end
            RUBY
            plugin.write "config/routes.rb", <<~RUBY
              Plugin::Engine.routes.draw do
                root to: proc { [200, {}, []] }

                resources(:posts)
              end
            RUBY
          end
        end

        def app_url_helpers
          Rails.application.routes.url_helpers
        end

        def engine_url_helpers
          Plugin::Engine.routes.url_helpers
        end
    end
  end
end
