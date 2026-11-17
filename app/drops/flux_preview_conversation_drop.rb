class FluxPreviewConversationDrop < ConversationDrop
  attr_reader :unavailable

  def id
    @unavailable = true if @obj.new_record?
    super
  end

  alias display_id id
end
