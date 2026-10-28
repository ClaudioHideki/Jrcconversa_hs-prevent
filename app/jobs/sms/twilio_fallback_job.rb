class Sms::TwilioFallbackJob < ApplicationJob
  queue_as :high

  def perform(message_id)
    message = Message.find_by(id: message_id)
    Sms::TwilioFallbackService.new(message).perform if message
  end
end
