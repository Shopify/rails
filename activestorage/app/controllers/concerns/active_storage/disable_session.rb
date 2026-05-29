# frozen_string_literal: true

# This concern disables the session in order to allow caching by default in some CDNs as CloudFlare.
module ActiveStorage::DisableSession
  extend ActiveSupport::Concern

  included do
    before_action :disable_active_storage_session
  end

  private
    def disable_active_storage_session
      request.session_options[:skip] = true
    end
end
