class Person < ApplicationRecord
  include ActionText::Attachable

  def to_trix_content_attachment_partial_path
    "people/trix_content_attachment"
  end

  def to_attachable_partial_path
    "people/attachable"
  end
end
