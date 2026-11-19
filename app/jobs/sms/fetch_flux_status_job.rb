class Sms::FetchFluxStatusJob < ApplicationJob
  queue_as :low
  self.log_arguments = false
  MAX_ATTEMPTS = 288

  def perform(channel_id, message_id, attempt = 0)
    return unless attempt.between?(0, MAX_ATTEMPTS - 1)

    channel = polling_channel(channel_id)
    return unless channel

    message = pending_message(channel, message_id)
    return unless message
    poll(channel, message) if reserve_query(channel, message)
    return unless message.reload.sent? && attempt + 1 < MAX_ATTEMPTS

    self.class.set(wait: 5.minutes).perform_later(channel.id, message.id, attempt + 1)
  end

  private

  def polling_channel(channel_id)
    channel = Channel::Sms.find_by(id: channel_id, provider: 'flux')
    channel if channel&.inbox && channel.inbox.account_id == channel.account_id
  end

  def pending_message(channel, message_id)
    message = channel.inbox.messages.find_by(id: message_id, account_id: channel.account_id, private: false,
                                             status: :sent, message_type: [:outgoing, :template])
    message if message&.content_attributes&.fetch('flux_partner_id', nil).present?
  end

  def reserve_query(channel, message)
    account = channel.flux_secrets.fetch('account').downcase
    identity = Digest::SHA256.hexdigest([account, message.content_attributes['flux_partner_id']].to_json)
    Redis::Alfred.set("flux_status_query:#{identity}", '1', nx: true, ex: 90)
  end

  def poll(channel, message)
    Sms::FluxStatusLookup.new(channel).perform(message)
  rescue Sms::FluxStatusLookup::Error
    Rails.logger.warn("Flux status: inbox=#{channel.inbox.id} message=#{message.id} query failed; bounded retry scheduled")
  end
end
