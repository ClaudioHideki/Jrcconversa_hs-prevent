class Sms::FluxStatusLookup
  class Error < StandardError; end

  STATUSES = {
    '101' => 'ANALISE LINK (APROVACAO EM ANDAMENTO AGUARDAR)', '110' => 'ENVIADA', '111' => 'ACEITA',
    '120' => 'ENTREGUE', '130' => 'BLOQUEADA', '131' => 'EM ANALISE', '132' => 'CANCELADO',
    '138' => 'EM ANALISE', '139' => 'AGENDADO', '146' => 'NAO ENTREGUE', '150' => 'EXPIRADA',
    '161' => 'REJEITADA', '162' => 'BLOQUEADA', '163' => 'ANALISE OPERADORA', '171' => 'NUMERO INVALIDO',
    '172' => 'REJEITADA', '173' => 'NUMERO FIXO', '174' => 'USUARIO SEM CREDITO', '175' => 'SPAM'
  }.freeze

  def initialize(channel)
    @channel = channel
  end

  def perform(message)
    return unless message.account_id == @channel.account_id && message.inbox_id == @channel.inbox.id

    partner = message.content_attributes.fetch('flux_partner_id')
    rows = fetch_rows(partner)
    rows.each do |row|
      next unless row.is_a?(Hash) && row['id_parceiro'].to_s == partner

      event = callback_event(message, row)
      Sms::FluxCallbackService.new(@channel, event).perform if event
    end
  end

  private

  def fetch_rows(partner)
    secrets = @channel.flux_secrets
    response = HTTParty.get("#{Sms::Providers::FluxService::API_BASE}/integracao3.do",
                            query: { account: secrets.fetch('account'), code: secrets.fetch('code'), type: 'C', id: partner },
                            timeout: 20, follow_redirects: false)
    raise Error, 'Flux status: HTTP failure' unless response.code.to_i == 200

    data = JSON.parse(response.body)
    raise Error, 'Flux status: query refused' unless data.is_a?(Hash) && [nil, '', '000'].include?(data['codigo'].to_s.presence)
    raise Error, 'Flux status: invalid response' unless data['mensagens'].is_a?(Array)

    data['mensagens']
  rescue JSON::ParserError, Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, HTTParty::Error
    raise Error, 'Flux status: unavailable or invalid response'
  end

  def callback_event(message, row)
    status = STATUSES[row['id_status'].to_s]
    return unless status && row['id_mensagem'].to_s.match?(/\A\d+\z/)

    time = status_time(row)
    return unless time

    { telefone: message.content_attributes['flux_phone'], id: row['id_mensagem'].to_s,
      idParceiro: row['id_parceiro'], status: status, data: time.iso8601 }
  end

  def status_time(row)
    return Sms::FluxReplyService.received_time(row['data_entrega'], source: :api) if row['id_status'].to_s == '120'

    Sms::FluxReplyService.received_time(row['data_entrega'], source: :api) || Time.current
  end
end
