# frozen_string_literal: true

# :markup: markdown

require "active_support/core_ext/kernel/ractor_shareability"

module ActionController
  # Specify binary encoding for parameters for a given action.
  module ParameterEncoding
    extend ActiveSupport::Concern

    module ClassMethods
      def inherited(klass) # :nodoc:
        super
        klass.setup_param_encode
      end

      def setup_param_encode # :nodoc:
        @_parameter_encodings = ractor_make_shareable({})
      end

      def action_encoding_template(action) # :nodoc:
        if @_parameter_encodings.has_key?(action.to_s)
          @_parameter_encodings[action.to_s]
        end
      end

      # Specify that a given action's parameters should all be encoded as ASCII-8BIT
      # (it "skips" the encoding default of UTF-8).
      #
      # For example, a controller would use it like this:
      #
      #     class RepositoryController < ActionController::Base
      #       skip_parameter_encoding :show
      #
      #       def show
      #         @repo = Repository.find_by_filesystem_path params[:file_path]
      #
      #         # `repo_name` is guaranteed to be UTF-8, but was ASCII-8BIT, so
      #         # tag it as such
      #         @repo_name = params[:repo_name].force_encoding 'UTF-8'
      #       end
      #
      #       def index
      #         @repositories = Repository.all
      #       end
      #     end
      #
      # The show action in the above controller would have all parameter values
      # encoded as ASCII-8BIT. This is useful in the case where an application must
      # handle data but encoding of the data is unknown, like file system data.
      def skip_parameter_encoding(action)
        template = ractor_make_shareable(Hash.new(Encoding::ASCII_8BIT))
        @_parameter_encodings = ractor_make_shareable(@_parameter_encodings.merge(action.to_s => template))
      end

      # Specify the encoding for a parameter on an action. If not specified the
      # default is UTF-8.
      #
      # You can specify a binary (ASCII_8BIT) parameter with:
      #
      #     class RepositoryController < ActionController::Base
      #       # This specifies that file_path is not UTF-8 and is instead ASCII_8BIT
      #       param_encoding :show, :file_path, Encoding::ASCII_8BIT
      #
      #       def show
      #         @repo = Repository.find_by_filesystem_path params[:file_path]
      #
      #         # params[:repo_name] remains UTF-8 encoded
      #         @repo_name = params[:repo_name]
      #       end
      #
      #       def index
      #         @repositories = Repository.all
      #       end
      #     end
      #
      # The file_path parameter on the show action would be encoded as ASCII-8BIT, but
      # all other arguments will remain UTF-8 encoded. This is useful in the case
      # where an application must handle data but encoding of the data is unknown,
      # like file system data.
      def param_encoding(action, param, encoding)
        action = action.to_s
        template = (@_parameter_encodings[action] || {}).merge(param.to_s => encoding)
        @_parameter_encodings = ractor_make_shareable(@_parameter_encodings.merge(action => template))
      end
    end
  end
end
