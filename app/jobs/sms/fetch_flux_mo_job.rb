class Sms::FetchFluxMoJob < ApplicationJob
  queue_as :low

  def perform(channel_id)
    channel = Channel::Sms.find_by(id: channel_id, provider: 'flux')
    return unless channel&.inbox && channel.flux_mo_polling_enabled?
    return if Redis::Alfred.exists?("flux_mo_cooldown:#{channel.id}")

    key = "flux_mo_poll:#{channel.id}"
    token = SecureRandom.hex(16)
    return unless Redis::Alfred.set(key, token, nx: true, ex: 4.minutes.to_i)

    begin
      replies = Sms::Providers::FluxService.new(channel).fetch_replies
      known_ids = channel.inbox.messages.incoming
                         .where("content_attributes ->> 'flux_mo_id' IN (?)", replies.pluck('idResposta'))
                         .pluck(Arel.sql("content_attributes ->> 'flux_mo_id'")).to_set
      unseen = replies.reject { |event| known_ids.include?(event['idResposta']) }
      imported = unseen.count { |event| Sms::FluxReplyService.new(channel, event, source: :api).perform == :created }
      Rails.logger.info("Flux MO: inbox=#{channel.inbox.id} queried=#{replies.size} imported=#{imported}")
    ensure
      Redis::Alfred.delete_if_equals(key, token)
    end
  rescue Sms::FluxMoResponseParser::RateLimitError
    Redis::Alfred.set("flux_mo_cooldown:#{channel_id}", '1', ex: 5.minutes.to_i)
    Rails.logger.warn("Flux MO: channel=#{channel_id} limite 910; consultas pausadas por 5 minutos.")
  rescue Sms::Providers::FluxService::Error, Sms::FluxMoResponseParser::Error => error
    Rails.logger.warn("Flux MO: channel=#{channel_id} #{error.message}")
  end
end
