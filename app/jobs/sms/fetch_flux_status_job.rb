class Sms::FetchFluxStatusJob < ApplicationJob
  queue_as :low
  self.log_arguments = false
  MAX_ATTEMPTS = 1330
  INTERVAL = 65.seconds
  ERROR_INTERVAL = 5.minutes

  def perform(channel_id, message_id, attempt = 0)
    return unless attempt.between?(0, MAX_ATTEMPTS - 1)

    channel = polling_channel(channel_id)
    return unless channel

    message = pending_message(channel, message_id)
    return unless message

    delay = query_delay(channel, message)
    return unless message.reload.sent? && attempt + 1 < MAX_ATTEMPTS

    self.class.set(wait: delay).perform_later(channel.id, message.id, attempt + 1)
  end

  private

  def polling_channel(channel_id)
    channel = Channel::Sms.find_by(id: channel_id, provider: 'flux')
    channel if channel&.inbox && channel.inbox.account_id == channel.account_id
  end

  def pending_message(channel, message_id)
    scope = channel.inbox.messages.where('created_at >= ?', 24.hours.ago)
    message = scope.find_by(id: message_id, account_id: channel.account_id, private: false,
                            status: :sent, message_type: [:outgoing, :template])
    message if message&.content_attributes&.fetch('flux_partner_id', nil).present?
  end

  def query_delay(channel, message)
    return poll(channel, message) if reserve_query(channel, message)

    [INTERVAL, Redis::Alfred.ttl(@query_key)].max
  end

  def reserve_query(channel, message)
    account = channel.flux_secrets.fetch('account').downcase
    identity = Digest::SHA256.hexdigest([account, message.content_attributes['flux_partner_id']].to_json)
    @query_key = "flux_status_query:#{identity}"
    Redis::Alfred.set(@query_key, '1', nx: true, ex: INTERVAL.to_i)
  end

  def poll(channel, message)
    Sms::FluxStatusLookup.new(channel).perform(message)
    INTERVAL
  rescue Sms::FluxStatusLookup::Error
    Redis::Alfred.expire(@query_key, ERROR_INTERVAL.to_i)
    Rails.logger.warn("Flux status: inbox=#{channel.inbox.id} message=#{message.id} query failed; bounded retry scheduled")
    ERROR_INTERVAL
  end
end
