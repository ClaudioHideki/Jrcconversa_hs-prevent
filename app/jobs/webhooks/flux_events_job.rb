class Webhooks::FluxEventsJob < ApplicationJob
  queue_as :default

  def perform(channel_id, events)
    channel = Channel::Sms.find_by(id: channel_id, provider: 'flux')
    return unless channel&.inbox

    events.each { |event| Sms::FluxCallbackService.new(channel, event).perform }
  end
end
