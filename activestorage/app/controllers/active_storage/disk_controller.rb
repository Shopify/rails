# frozen_string_literal: true

# Serves files stored with the disk service in the same way that the cloud services do.
# This means using expiring, signed URLs that are meant for immediate access, not permanent linking.
# Always go through the BlobsController, or your own authenticated controller, rather than directly
# to the service URL.
class ActiveStorage::DiskController < ActiveStorage::BaseController
  include ActiveStorage::FileServer

  if respond_to?(:skip_forgery_protection)
    skip_forgery_protection
  end

  def show
    if key = decode_verified_key
      serve_file named_disk_service(key[:service_name]).path_for(key[:key]), content_type: key[:content_type], disposition: key[:disposition]
    else
      head :not_found
    end
  rescue Errno::ENOENT
    head :not_found
  rescue ActiveStorage::InvalidKeyError
    head :not_found
  end

  def update
    if token = decode_verified_token
      if acceptable_content?(token)
        named_disk_service(token[:service_name]).upload token[:key], request.body, checksum: token[:checksum]
        head :no_content
      else
        head ActionDispatch::Constants::UNPROCESSABLE_CONTENT
      end
    else
      head :not_found
    end
  rescue ActiveStorage::IntegrityError
    head ActionDispatch::Constants::UNPROCESSABLE_CONTENT
  rescue ActiveStorage::InvalidKeyError
    head ActionDispatch::Constants::UNPROCESSABLE_CONTENT
  end

  private
    def named_disk_service(name)
      ActiveStorage::Blob.services.fetch(name) do
        ActiveStorage::Blob.service
      end
    end

    def decode_verified_key
      decode params[:encoded_key], purpose: :blob_key
    end

    # Upload URLs minted before the token purpose was split out were signed as :blob_key.
    def decode_verified_token
      decode(params[:encoded_token], purpose: :blob_token) || decode(params[:encoded_token], purpose: :blob_key)
    end

    def decode(message, purpose:)
      ActiveStorage.verifier.verified(message, purpose: purpose)&.deep_symbolize_keys
    end

    def acceptable_content?(token)
      token[:content_type] == request.content_mime_type && token[:content_length].to_i == request.content_length
    end
end
