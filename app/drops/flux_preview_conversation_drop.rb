class FluxPreviewConversationDrop < ConversationDrop
  def initialize(conversation, on_unavailable:)
    super(conversation)
    @on_unavailable = on_unavailable
  end

  def id
    @on_unavailable.call if @obj.new_record?
    super
  end

  alias display_id id

  def to_s
    ConversationDrop.new(@obj).to_s
  end

  alias inspect to_s
end
