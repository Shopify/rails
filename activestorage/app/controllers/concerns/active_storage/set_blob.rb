# frozen_string_literal: true

module ActiveStorage::SetBlob # :nodoc:
  extend ActiveSupport::Concern

  included do
    before_action :set_blob
  end

  private
    def set_blob
      @blob = blob_scope.find_signed(blob_id) || blob_scope.find_by(id: blob_id)
      head :not_found unless @blob
    end

    # Admin tooling and the console link to blobs by record id.
    def blob_id
      params[:signed_blob_id] || params[:signed_id]
    end

    def blob_scope
      ActiveStorage::Blob
    end
end
