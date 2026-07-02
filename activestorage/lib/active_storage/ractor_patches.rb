# frozen_string_literal: true

# ActiveStorage Ractor patches, applied by Rails::Application#ractorize!.
#
# ActiveStorage keeps its configuration in module-level mattr_accessors backed by
# class variables (@@analyze, @@queues, ...). Class variables can't be read from
# a non-main Ractor, so capture each reader's value on the main Ractor and serve
# it to non-main Ractors (see ActiveSupport::Ractors.capture_class_reader).

require "active_support/ractors"

%i[
  variant_processor queues previewers analyzers analyze paths
  variable_content_types web_image_content_types binary_content_type
  content_types_to_serve_as_binary content_types_allowed_inline
  supported_image_processing_methods unsupported_image_processing_arguments
  streaming_chunk_max_size service_urls_expire_in touch_attachment_records
  urls_expire_in routes_prefix draw_routes resolve_model_to_route
  track_variants video_preview_arguments
].each do |name|
  next unless ActiveStorage.respond_to?(name)
  ActiveSupport::Ractors.capture_class_reader(ActiveStorage, name)
end

# Metadata extraction shells out to image libraries (ruby-vips / MiniMagick).
# ruby-vips in particular caches introspection in a class variable
# (Vips::Introspect@@introspect_cache) and dispatches through GLib -- neither of
# which is reachable from a non-main Ractor. Rather than reimplement the C
# bindings, dispatch the analysis to the main Ractor (which owns the store and
# the native libraries) and bring back the resulting metadata Hash, which is
# made of shareable scalars.
if defined?(ActiveStorage::Blob)
  module ActiveStorage
    module RactorAnalyzeDispatch
      private
        def extract_metadata_via_analyzer
          return super if Ractor.main? || !persisted?

          blob_id = id
          Ractor::Dispatch.main.run do
            metadata = ActiveStorage::Blob.find(blob_id).send(:extract_metadata_via_analyzer)
            Ractor.make_shareable(metadata)
          end
        end
    end
  end
  ActiveStorage::Blob.prepend(ActiveStorage::RactorAnalyzeDispatch)
end
