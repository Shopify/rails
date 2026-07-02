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
          # During a fresh upload the analysis runs from a local io *before* the
          # bytes are written to the store (see Attachment#uploaded). Forward
          # that io's path so the main Ractor analyzes the same local file
          # instead of downloading a not-yet-uploaded blob.
          # Single assignment: a shareable Proc can't capture a reassigned local.
          io_path = begin
            candidate = (local_io.path if local_io.respond_to?(:path)) rescue nil
            candidate && File.exist?(candidate) ? -candidate.to_s : nil
          end

          Ractor::Dispatch.main.run do
            blob = ActiveStorage::Blob.find(blob_id)
            metadata =
              if io_path
                File.open(io_path, "rb") do |file|
                  blob.local_io = file
                  begin
                    blob.send(:extract_metadata_via_analyzer)
                  ensure
                    blob.local_io = nil
                  end
                end
              else
                blob.send(:extract_metadata_via_analyzer)
              end
            Ractor.make_shareable(metadata)
          end
        end
    end
  end
  ActiveStorage::Blob.prepend(ActiveStorage::RactorAnalyzeDispatch)

  # Enqueuing jobs (SyncMetadataJob, AnalyzeJob, PurgeJob, MirrorJob) reads
  # ActiveJob class_attributes (queue_name and friends) whose defaults are Procs
  # -- unreadable from a non-main Ractor. Dispatch the enqueue to the main
  # Ractor, reconstructing the blob by id there.
  module ActiveStorage
    module RactorJobEnqueueDispatch
      def sync_metadata_later
        dispatch_blob_job_to_main(:sync_metadata_later) { super }
      end

      def analyze_later
        dispatch_blob_job_to_main(:analyze_later) { super }
      end

      def purge_later
        dispatch_blob_job_to_main(:purge_later) { super }
      end

      def mirror_later
        dispatch_blob_job_to_main(:mirror_later) { super }
      end

      private
        def dispatch_blob_job_to_main(meth)
          return yield if Ractor.main? || !persisted?

          blob_id = id
          Ractor::Dispatch.main.run do
            ActiveStorage::Blob.find(blob_id).public_send(meth)
            nil
          end
        end
    end
  end
  ActiveStorage::Blob.prepend(ActiveStorage::RactorJobEnqueueDispatch)
end
