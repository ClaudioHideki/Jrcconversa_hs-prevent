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
    phone = value.to_s.gsub(/\D/, '')
    phone = "55#{phone}" if [10, 11].include?(phone.length)
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
    message.with_lock do
      message.update!(content_attributes: message.content_attributes.merge('flux_partner_id' => partner_id, 'flux_phone' => phone))
    end
    provider_id = send_text(phone, message.outgoing_content, partner_id: partner_id)
    message.with_lock do
      message.update!(source_id: provider_id) if message.source_id.blank?
    end
    provider_id
  rescue Error => e
    message.with_lock do
      unless message.delivered? || message.read?
        message.update!(status: :failed, content_attributes: message.content_attributes.merge('external_error' => e.message))
      end
    end
    nil
  end

  def send_text(phone, text, partner_id: "JRC-#{SecureRandom.uuid}")
    phone = self.class.normalize_phone(phone)
    limit = @channel.provider_config['send_type'].to_s == '4' ? 1280 : 160
    raise Error, "Flux: a mensagem deve conter de 1 a #{limit} caracteres." if text.blank? || text.length > limit

    secrets = @channel.flux_secrets
    body = {
      to: phone, tipoEnvio: @channel.provider_config.fetch('send_type', '1').to_s,
      msg: text, id: partner_id, urlCallback: @channel.flux_callback_url, tokenCallback: secrets.fetch('callback_token')
    }
    body[:client] = @channel.provider_config['client'] if @channel.provider_config['client'].present?
    response = HTTParty.post(
      "#{API_BASE}/envio", headers: { 'Content-Type' => 'application/json', 'account' => secrets.fetch('account'), 'code' => secrets.fetch('code') },
      body: body.to_json, timeout: 20, follow_redirects: false
    )
    raise Error, 'Flux: API indisponivel.' unless response.success?

    parse_send_response(response.body, partner_id)
  rescue *network_errors
    # A timeout can occur after acceptance; do not automatically resend and charge twice.
    raise Error, 'Flux: envio sem confirmacao. Confira na Flux antes de tentar novamente.'
  end

  private

  def parse_send_response(body, partner_id)
    value = JSON.parse(body)
    if value.is_a?(Hash)
      code = value['codigo'].to_s
      raise Error, error_message(code) if code.present? && code != '000'
      return (value['id_mensagem'].presence || value['id'].presence || partner_id).to_s if code == '000' || value['id_mensagem'] || value['id']
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
