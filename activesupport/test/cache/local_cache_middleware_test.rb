# frozen_string_literal: true

require_relative "../abstract_unit"
require "active_support/cache"

module ActiveSupport
  module Cache
    module Strategy
      module LocalCache
        class MiddlewareTest < ActiveSupport::TestCase
          class Cache
            def initialize(key:)
              @key = key
            end

            def local_cache_key
              @key
            end
          end

          def test_local_cache_cleared_on_close
            cache = Cache.new(key: "super awesome key")
            assert_nil LocalCacheRegistry.cache_for cache.local_cache_key
            middleware = Middleware.new("<3", cache).new(->(env) {
              assert LocalCacheRegistry.cache_for(cache.local_cache_key), "should have a cache"
              [200, {}, []]
            })
            _, _, body = middleware.call({})
            assert LocalCacheRegistry.cache_for(cache.local_cache_key), "should still have a cache"
            body.each { }
            assert LocalCacheRegistry.cache_for(cache.local_cache_key), "should still have a cache"
            body.close
            assert_nil LocalCacheRegistry.cache_for(cache.local_cache_key)
          end

          def test_local_cache_cleared_and_response_should_be_present_on_invalid_parameters_error
            cache = Cache.new(key: "super awesome key")
            assert_nil LocalCacheRegistry.cache_for cache.local_cache_key
            middleware = Middleware.new("<3", cache).new(->(env) {
              assert LocalCacheRegistry.cache_for(cache.local_cache_key), "should have a cache"
              raise Rack::Utils::InvalidParameterError
            })
            response = middleware.call({})
            assert response, "response should exist"
            assert_nil LocalCacheRegistry.cache_for(cache.local_cache_key)
          end

          def test_local_cache_cleared_on_exception
            cache = Cache.new(key: "super awesome key")
            assert_nil LocalCacheRegistry.cache_for cache.local_cache_key
            middleware = Middleware.new("<3", cache).new(->(env) {
              assert LocalCacheRegistry.cache_for(cache.local_cache_key), "should have a cache"
              raise
            })
            assert_raises(RuntimeError) { middleware.call({}) }
            assert_nil LocalCacheRegistry.cache_for(cache.local_cache_key)
          end

          def test_local_cache_cleared_on_throw
            cache = Cache.new(key: "super awesome key")
            assert_nil LocalCacheRegistry.cache_for cache.local_cache_key
            middleware = Middleware.new("<3", cache).new(->(env) {
              assert LocalCacheRegistry.cache_for(cache.local_cache_key), "should have a cache"
              throw :warden
            })
            assert_throws(:warden) { middleware.call({}) }
            assert_nil LocalCacheRegistry.cache_for(cache.local_cache_key)
          end
        end
      end
    end
  end
end
