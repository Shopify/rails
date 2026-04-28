# frozen_string_literal: true

# :markup: markdown

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
        @_parameter_encodings = Hash.new { |h, k| h[k] = {} }
      end

      def action_encoding_template(action) # :nodoc:
        if @_parameter_encodings.has_key?(action.to_s)
          @_parameter_encodings[action.to_s]
        end
      end

      # Walk every controller class and replace its +@_parameter_encodings+
      # Hash with a shareable snapshot. The boot-time storage uses
      # +Hash.new { |h, k| h[k] = {} }+ for auto-vivification and
      # +Hash.new { Encoding::ASCII_8BIT }+ for +skip_parameter_encoding+;
      # both default procs capture self (block scope) and prevent the
      # outer/inner Hashes from being shareable. The read path
      # (+action_encoding_template+) gates on +has_key?+, so the outer
      # default proc never fires at request time and can be dropped. For
      # the +skip_parameter_encoding+ inner Hash we preserve the
      # "missing key returns ASCII-8BIT" semantic by switching from a
      # default proc to a default value, which CustomParamEncoder reads
      # via plain +[]+.
      #
      # Also seals each class's +@__class_attr_middleware_stack+ in the
      # same descendants pass. Every controller class carries its own
      # storage (assigned in +ActionController::Metal.inherited+ via
      # +subclass.middleware_stack = middleware_stack.dup+), and the
      # +class_attribute+ reader is invoked on every routed request from
      # +ActionController::Metal.dispatch+ / +.action+ (+middleware_stack.any?+).
      def make_shareable!
        [self, *self.descendants].each do |klass|
          encodings = klass.instance_variable_get(:@_parameter_encodings)
          if encodings && !encodings.frozen?
            rebuilt = encodings.each_with_object({}) do |(action, inner), h|
              h[action] = if inner.default_proc
                Hash.new(Encoding::ASCII_8BIT).merge!(inner.to_h).freeze
              else
                inner.dup.freeze
              end
            end
            klass.instance_variable_set(:@_parameter_encodings, rebuilt.freeze)
          end

          stack_ivar = :@__class_attr_middleware_stack
          if klass.singleton_class.instance_variable_defined?(stack_ivar)
            stack = klass.singleton_class.instance_variable_get(stack_ivar)
            stack.make_shareable! if stack && !stack.frozen?
          end
        end
        super
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
        if @_parameter_encodings.frozen?
          raise FrozenError, "can't modify frozen @_parameter_encodings on #{self.name || self.inspect} after Rails.application.ractorize!"
        end
        @_parameter_encodings[action.to_s] = Hash.new { Encoding::ASCII_8BIT }
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
        if @_parameter_encodings.frozen?
          raise FrozenError, "can't modify frozen @_parameter_encodings on #{self.name || self.inspect} after Rails.application.ractorize!"
        end
        @_parameter_encodings[action.to_s][param.to_s] = encoding
      end
    end
  end
end
