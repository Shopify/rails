# frozen_string_literal: true

# :markup: markdown

require "active_support/core_ext/kernel/ractor_shareability"

module ActionController # :nodoc:
  module ContentSecurityPolicy
    extend ActiveSupport::Concern

    include AbstractController::Helpers
    include AbstractController::Callbacks

    included do
      helper_method :content_security_policy?
      helper_method :content_security_policy_nonce
    end

    module ClassMethods
      # Overrides parts of the globally configured `Content-Security-Policy` header:
      #
      #     class PostsController < ApplicationController
      #       content_security_policy do |policy|
      #         policy.base_uri "https://www.example.com"
      #       end
      #     end
      #
      # Options can be passed similar to `before_action`. For example, pass `only:
      # :index` to override the header on the index action only:
      #
      #     class PostsController < ApplicationController
      #       content_security_policy(only: :index) do |policy|
      #         policy.default_src :self, :https
      #       end
      #     end
      #
      # Pass `false` to remove the `Content-Security-Policy` header:
      #
      #     class PostsController < ApplicationController
      #       content_security_policy false, only: :index
      #     end
      def content_security_policy(enabled = true, **options, &block)
        before_action ContentSecurityPolicyCallback.new(enabled, block), **options
      end

      # Overrides the globally configured `Content-Security-Policy-Report-Only`
      # header:
      #
      #     class PostsController < ApplicationController
      #       content_security_policy_report_only only: :index
      #     end
      #
      # Pass `false` to remove the `Content-Security-Policy-Report-Only` header:
      #
      #     class PostsController < ApplicationController
      #       content_security_policy_report_only false, only: :index
      #     end
      def content_security_policy_report_only(report_only = true, **options)
        before_action ContentSecurityPolicyReportOnlyCallback.new(report_only), **options
      end

      class ContentSecurityPolicyCallback # :nodoc:
        def initialize(enabled, block)
          @enabled = enabled
          @block = block && ractor_make_shareable(block)
        end

        def before(controller)
          if @block
            policy = controller.send(:current_content_security_policy)
            controller.instance_exec(policy, &@block)
            controller.request.content_security_policy = policy
          end

          unless @enabled
            controller.request.content_security_policy = nil
          end
        end
      end

      class ContentSecurityPolicyReportOnlyCallback # :nodoc:
        def initialize(report_only)
          @report_only = report_only
        end

        def before(controller)
          controller.request.content_security_policy_report_only = @report_only
        end
      end
    end

    private
      def content_security_policy?
        request.content_security_policy
      end

      def content_security_policy_nonce
        request.content_security_policy_nonce
      end

      def current_content_security_policy
        request.content_security_policy&.clone || ActionDispatch::ContentSecurityPolicy.new
      end
  end
end
