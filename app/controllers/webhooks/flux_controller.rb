class Webhooks::FluxController < ActionController::API
  def process_payload
    events = callback_events
    return head :unprocessable_entity unless valid_events?(events)

    batches = authenticated_batches(events)
    return head :unauthorized unless batches

    batches.each do |channel_id, batch|
      return head :service_unavailable unless Webhooks::FluxEventsJob.perform_later(channel_id, batch)
    end
    render plain: 'OK'
  end

  private

  def callback_events
    raw = request.request_parameters
    raw['_json'] || raw['mensagens'] || [raw]
  end

  def authenticated_batches(events)
    events.each_with_object({}) do |event, batches|
      channel = authenticated_channel(event.fetch('token') { fallback_token })
      return nil unless channel

      (batches[channel.id] ||= []) << event.slice('telefone', 'data', 'id', 'idParceiro', 'idResposta', 'status', 'resposta')
    end
  end

  def authenticated_channel(token)
    return unless token.is_a?(String) && token.bytesize.between?(1, 50)

    digest = Digest::SHA256.hexdigest(token)
    @channels ||= {}
    @channels[digest] ||= Channel::Sms.find_by(provider: 'flux', flux_callback_digest: digest)
  end

  def fallback_token
    raw = request.request_parameters
    return if raw.key?('_json')
    return raw['token'] if raw.key?('token')

    params[:t].presence || request.headers['tokenCallback'].presence || params[:tokenCallback].presence
  end

  def valid_events?(events)
    events.is_a?(Array) && events.size.between?(1, 1000) && events.all?(Hash)
  end
end
