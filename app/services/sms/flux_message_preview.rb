class Sms::FluxMessagePreview
  def initialize(conversation:, sender:, content:)
    @conversation = conversation
    @sender = sender
    @content = content
  end

  def perform
    message = @conversation.messages.build(
      account: @conversation.account, inbox: @conversation.inbox, sender: @sender,
      content: @content, message_type: :outgoing, content_type: :text, private: false
    )
    conversation_drop = FluxPreviewConversationDrop.new(@conversation)
    message.content = message.rendered_liquid_content(conversation_drop: conversation_drop)
    if conversation_drop.unavailable
      return { limit: Sms::FluxMessageLength.limit_for(@conversation.inbox.channel), valid: false, reason: 'conversation_not_created' }
    end
    analysis = Sms::FluxMessageLength.analyze(message.outgoing_content, @conversation.inbox.channel)
    FluxSmsLengthValidator.new.validate(message)
    analysis.merge(valid: message.errors.empty? && !analysis[:empty])
  end
end
