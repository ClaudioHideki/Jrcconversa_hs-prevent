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
    message.content = message.rendered_liquid_content
    analysis = Sms::FluxMessageLength.analyze(message.outgoing_content, @conversation.inbox.channel)
    FluxSmsLengthValidator.new.validate(message)
    analysis.merge(valid: message.errors.empty? && !analysis[:empty])
  end
end
