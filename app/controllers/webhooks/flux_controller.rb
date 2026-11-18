class Webhooks::FluxController < ActionController::API
  def process_payload
    channel = authenticated_channel
    return head :unauthorized unless channel

    raw = request.request_parameters
    events = raw['mensagens'] || [raw]
    return head :unprocessable_entity unless valid_events?(events)

    events = events.map { |event| event.slice('telefone', 'data', 'id', 'idParceiro', 'idResposta', 'status', 'resposta') }
    Webhooks::FluxEventsJob.perform_later(channel.id, events)
    render plain: 'OK'
  end

  private

  def authenticated_channel
    token = callback_token
    return unless token.is_a?(String) && token.bytesize.between?(1, 50)

    Channel::Sms.find_by(provider: 'flux', flux_callback_digest: Digest::SHA256.hexdigest(token))
  end

  def callback_token
    raw = request.request_parameters
    tokens = event_tokens
    tokens << raw['token'] if raw.key?('token')
    return if tokens.uniq.size > 1
    return tokens.first unless tokens.empty?

    params[:t].presence || request.headers['tokenCallback'].presence || params[:tokenCallback].presence
  end

  def event_tokens
    events = request.request_parameters['mensagens']
    return [] unless events.is_a?(Array) && events.size <= 1000

    events.select { |event| event.is_a?(Hash) && event.key?('token') }.map { |event| event['token'] }
  end

  def valid_events?(events)
    events.is_a?(Array) && events.size.between?(1, 1000) && events.all?(Hash)
  end
end
