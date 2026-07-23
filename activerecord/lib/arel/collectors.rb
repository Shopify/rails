# frozen_string_literal: true

module Arel # :nodoc: all
  module Collectors
    extend ActiveSupport::Autoload

    eager_autoload do
      autoload :Bind
      autoload :Composite
      autoload :PlainString
      autoload :SQLString
      autoload :SubstituteBinds
    end
  end
end
