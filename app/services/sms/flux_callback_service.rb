class Sms::FluxCallbackService
  FAILED = ['NAO ENTREGUE', 'EXPIRADA', 'DELETADA', 'REJEITADA', 'CANCELADO', 'NUMERO INVALIDO', 'BLOQUEADA',
            'CARACTERES LIMITE EXCEDIDO', 'NUMERO BLOQUEADO', 'NUMERO FIXO', 'USUARIO SEM CREDITO', 'SPAM'].freeze
  PENDING = ['ENVIADA', 'ACEITA', 'EM ANALISE', 'AGENDADO', 'EM ANALISE DE ENVIO PARA OPERADORA',
             'ANALISE OPERADORA', 'ANALISE LINK (APROVACAO EM ANDAMENTO AGUARDAR)'].freeze

  def initialize(channel, event)
    @channel = channel
    @event = event.with_indifferent_access
  end

  def perform
    return unless valid_channel?

    @phone = Sms::Providers::FluxService.normalize_phone(@event[:telefone])
    @status = ActiveSupport::Inflector.transliterate(@event[:status].to_s).upcase.strip
    return Sms::FluxReplyService.new(@channel, @event).perform if @status == 'RESPOSTA'
    return unless known_status?

    @time = Sms::FluxReplyService.received_time(@event[:data])
    return unless @time

    @channel.with_lock do
      @outgoing = find_outgoing
      next unless matching_phone?

      update_status
    end
  rescue Sms::Providers::FluxService::Error
    Rails.logger.warn("Flux: callback with invalid phone for SMS channel #{@channel.id}")
  end

  private

  def valid_channel?
    @channel.flux? && @channel.inbox&.account_id == @channel.account_id
  end

  def known_status?
    @status == 'ENTREGUE' || FAILED.include?(@status) || PENDING.include?(@status)
  end

  def matching_phone?
    @outgoing && @outgoing.content_attributes['flux_phone'] == @phone
  end

  def find_outgoing
    messages = @channel.inbox.messages.where(account_id: @channel.account_id, private: false, message_type: [:outgoing, :template])
    partner_id = @event[:idParceiro].presence || (@event[:id].to_s if @event[:id].to_s.start_with?('JRC-SMS-'))
    message = if partner_id
                find_by_partner(messages, partner_id.to_s)
              elsif @event[:id].present?
                messages.find_by(source_id: @event[:id].to_s)
              end
    return unless message && !conflicting_provider_id?(message)

    message
  end

  def find_by_partner(messages, partner_id)
    match = partner_id.match(/\AJRC-SMS-(\d+)\z/)
    return unless match

    message = messages.find_by(id: match[1])
    message if message&.content_attributes&.fetch('flux_partner_id', nil) == partner_id
  end

  def conflicting_provider_id?(message)
    provider_id = @event[:id].to_s.presence
    known_id = message.content_attributes['flux_id'].presence || (message.source_id unless provisional_source_id?(message))
    return false if known_id == message.content_attributes['flux_partner_id']

    provider_id && known_id && known_id != provider_id
  end

  def provisional_source_id?(message)
    origin_id = message.content_attributes['flux_fallback_origin_message_id']
    reserved_id = "flux-fallback-reserved-#{origin_id}" if origin_id.present?
    message.source_id.blank? || message.source_id == message.content_attributes['flux_partner_id'] || message.source_id == reserved_id
  end

  def update_status
    return unless @outgoing

    @outgoing.with_lock do
      next if stale_status?

      @outgoing.assign_attributes(status: target_status, content_attributes: status_attributes)
      assign_source_id
      @outgoing.save! if @outgoing.changed?
    end
  end

  def stale_status?
    return true if @outgoing.status.in?(%w[delivered read])
    return true if @outgoing.failed? && @status != 'ENTREGUE'

    previous_time = Sms::FluxReplyService.received_time(@outgoing.content_attributes['flux_status_at'])
    previous_time && @time < previous_time
  end

  def target_status
    return :delivered if @status == 'ENTREGUE'

    FAILED.include?(@status) ? :failed : :sent
  end

  def status_attributes
    attrs = @outgoing.content_attributes.merge('flux_status' => @event[:status].to_s, 'flux_status_at' => @time.iso8601)
    attrs['flux_id'] = @event[:id].to_s if @event[:id].present?
    attrs['external_error'] = target_status == :failed ? "Flux: #{@event[:status]}" : nil
    attrs
  end

  def assign_source_id
    partner_id = @outgoing.content_attributes['flux_partner_id']
    return unless provisional_source_id?(@outgoing)

    @outgoing.source_id = @event[:id].to_s.presence || partner_id
  end
end
