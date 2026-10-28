class Webhooks::FluxController < ActionController::API
  def process_payload
    token = params[:t].presence || request.headers['tokenCallback'].presence || params[:tokenCallback].presence
    return head :unauthorized if token.blank? || token.bytesize > 50

    channel = Channel::Sms.find_by(provider: 'flux', flux_callback_digest: Digest::SHA256.hexdigest(token))
    return head :unauthorized unless channel

    raw = request.request_parameters
    events = raw['mensagens'] || [raw]
    return head :unprocessable_entity unless events.is_a?(Array) && events.size.between?(1, 1000) && events.all? { |event| event.is_a?(Hash) }

    events = events.map { |event| event.slice('telefone', 'data', 'id', 'idParceiro', 'idResposta', 'status', 'resposta') }
    Webhooks::FluxEventsJob.perform_later(channel.id, events)
    render plain: 'OK'
  end
end
