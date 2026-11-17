class Sms::Providers::FluxService
  class Error < StandardError; end

  API_BASE = 'https://apisms.fluxtelecom.com.br'.freeze
  ERRORS = {
    '013' => 'Numero invalido', '171' => 'Numero invalido', '146' => 'Mensagem nao entregue',
    '161' => 'Rejeitada pela operadora', '162' => 'Bloqueada pela operadora', '174' => 'Usuario sem credito',
    '175' => 'Mensagem classificada como spam', '900' => 'Login ou senha invalidos',
    '901' => 'IP nao autorizado na Flux. Libere o IP publico de saida do servidor JRC.',
    '910' => 'Limite de consultas excedido', '999' => 'Erro desconhecido na Flux'
  }.freeze

  def initialize(channel)
    @channel = channel
  end

  def self.normalize_phone(value)
    raw = value.to_s.strip
    phone = raw.gsub(/\D/, '')
    international = raw.start_with?('+', '00')
    phone = phone.delete_prefix('00') if raw.start_with?('00')
    phone = "55#{phone}" if !international && [10, 11].include?(phone.length)
    raise Error, 'Flux: informe um celular brasileiro com DDD.' unless phone.match?(/\A55[1-9]\d{9,10}\z/)

    phone
  end

  # A read-only lookup of a nonexistent correlation ID validates access without sending an SMS.
  def test_connection
    secrets = @channel.flux_secrets
    response = HTTParty.get(
      "#{API_BASE}/integracao3.do",
      query: { account: secrets.fetch('account'), code: secrets.fetch('code'), type: 'C', id: "JRC-CHECK-#{SecureRandom.hex(8)}" },
      timeout: 20, follow_redirects: false
    )
    raise Error, 'Flux: API indisponivel.' unless response.success?

    data = JSON.parse(response.body)
    raise Error, 'Flux: retorno de consulta inesperado.' unless data.is_a?(Hash)

    raise Error, error_message(data['codigo']) if data['codigo'].present? && data['codigo'].to_s != '000'
    raise Error, 'Flux: retorno de consulta inesperado.' unless data['mensagens'].is_a?(Array) || data['codigo'].to_s == '000'

    true
  rescue JSON::ParserError
    raise Error, 'Flux: retorno de consulta invalido.'
  rescue *network_errors
    raise Error, 'Flux: falha de conexao HTTPS. Verifique a rede do servidor.'
  end

  def send_message(phone, message)
    raise Error, 'Flux SMS aceita somente texto.' if message.attachments.present?

    partner_id = "JRC-SMS-#{message.id}"
    phone = self.class.normalize_phone(phone)
    return message.source_id unless reserve_attempt(message, partner_id, phone)

    provider_id = send_text(phone, message.outgoing_content, partner_id: partner_id)
    message.with_lock do
      message.update!(source_id: provider_id) if message.source_id.blank?
    end
    provider_id
  rescue Error => e
    record_failure(message, e.message)
    nil
  end

  def fetch_replies
    secrets = @channel.flux_secrets
    today = Time.current.in_time_zone('America/Sao_Paulo').to_date
    response = HTTParty.get(
      "#{API_BASE}/pesquisaResposta",
      query: { account: secrets.fetch('account'), code: secrets.fetch('code'),
               dataInicio: (today - 1).strftime('%d/%m/%Y'), dataFim: today.strftime('%d/%m/%Y') },
      timeout: 20, follow_redirects: false
    )
    raise Error, 'Flux MO: API indisponivel.' unless response.code.to_i == 200

    Sms::FluxMoResponseParser.parse(response.body)
  rescue *network_errors
    raise Error, 'Flux MO: falha de conexao HTTPS; a consulta sera retomada no proximo ciclo.'
  end

  def send_text(phone, text, partner_id: "JRC-#{SecureRandom.uuid}")
    phone = self.class.normalize_phone(phone)
    limit = Sms::FluxMessageLength.limit_for(@channel)
    raise Error, "Flux: a mensagem deve conter de 1 a #{limit} caracteres." if text.blank? || text.length > limit

    secrets = @channel.flux_secrets
    body = {
      to: phone, tipoEnvio: @channel.provider_config.fetch('send_type', '1').to_s,
      msg: text, id: partner_id, urlCallback: callback_url, tokenCallback: secrets.fetch('callback_token')
    }
    body[:client] = @channel.provider_config['client'] if @channel.provider_config['client'].present?
    response = HTTParty.post(
      "#{API_BASE}/envio", headers: { 'Content-Type' => 'application/json', 'account' => secrets.fetch('account'), 'code' => secrets.fetch('code') },
      body: body.to_json, timeout: 20, follow_redirects: false
    )
    raise Error, 'Flux: API indisponivel.' unless response.code.to_i == 200

    parse_send_response(response.body, partner_id)
  rescue *network_errors
    # A timeout can occur after acceptance; do not automatically resend and charge twice.
    raise Error, 'Flux: envio sem confirmacao. Confira na Flux antes de tentar novamente.'
  end

  private

  def callback_url
    url = @channel.flux_callback_url
    uri = URI.parse(url)
    return url if valid_callback_url?(uri, url)

    raise Error, 'Flux: configure FLUX_CALLBACK_BASE_URL com uma URL publica curta. O callback completo aceita no maximo 50 caracteres.'
  rescue URI::InvalidURIError
    raise Error, 'Flux: URL de callback invalida. Verifique FLUX_CALLBACK_BASE_URL.'
  end

  def valid_callback_url?(uri, url)
    uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.nil? && uri.fragment.nil? &&
      uri.query == "t=#{@channel.flux_secrets.fetch('callback_token')}" && url.bytesize <= 50
  end

  def reserve_attempt(message, partner_id, phone)
    message.with_lock do
      next false if message.content_attributes['flux_partner_id'].present?

      message.update!(content_attributes: message.content_attributes.merge('flux_partner_id' => partner_id, 'flux_phone' => phone))
      true
    end
  end

  def record_failure(message, error)
    message.with_lock do
      next if message.status.in?(%w[delivered read])
      next if message.failed? && message.content_attributes['flux_status'].present?

      message.update!(status: :failed, content_attributes: message.content_attributes.merge('external_error' => error))
    end
  end

  def parse_send_response(body, partner_id)
    value = JSON.parse(body)
    if value.is_a?(Hash)
      code = value['codigo'].to_s
      raise Error, error_message(code) if code.present? && code != '000'
      provider_id = value['id_mensagem'].presence || value['id'].presence
      return (provider_id || partner_id).to_s if code == '000' || provider_id
    end
    parse_plain_response(value.to_s, partner_id)
  rescue JSON::ParserError
    parse_plain_response(body.strip, partner_id)
  end

  def parse_plain_response(value, partner_id)
    return partner_id if value == partner_id || value == '000'
    return value if value.match?(/\A\d{4,}\z/)

    raise Error, error_message(value) if value.match?(/\A\d{1,3}\z/)

    raise Error, 'Flux: retorno de envio inesperado. Confira na plataforma antes de tentar novamente.'
  end

  def error_message(code)
    "Flux #{code}: #{ERRORS.fetch(code.to_s.rjust(3, '0'), 'Solicitacao recusada pela API')}"
  end

  def network_errors
    [Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, HTTParty::Error]
  end
end
