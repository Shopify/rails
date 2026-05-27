# frozen_string_literal: true

require "rack/body_proxy"
require "rack/utils"

module ActiveSupport
  module Cache
    module Strategy
      module LocalCache
        #--
        # This class wraps up local storage for middlewares. Only the middleware method should
        # construct them.
        class Middleware # :nodoc:
          attr_reader :name, :cache

          def initialize(name, cache)
            @name = name
            self.cache = cache
            @app = nil
          end

          def cache=(cache)
            @cache = cache
            @local_cache_key = cache.send(:local_cache_key)
          end

          def new(app)
            @app = app
            self
          end

          def call(env)
            new_local_cache
            response = @app.call(env)
            response[2] = ::Rack::BodyProxy.new(response[2]) do
              unset_local_cache
            end
            cleanup_on_body_close = true
            response
          rescue Rack::Utils::InvalidParameterError
            [400, {}, []]
          ensure
            unset_local_cache unless cleanup_on_body_close
          end

          def freeze
            @cache = nil
            super
          end

          private
            def new_local_cache
              LocalCacheRegistry.set_cache_for(@local_cache_key, LocalStore.new)
            end

            def unset_local_cache
              LocalCacheRegistry.set_cache_for(@local_cache_key, nil)
            end
        end
      end
    end
  end
end
