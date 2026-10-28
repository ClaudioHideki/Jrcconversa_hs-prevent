class Sms::FluxCallbackService
  FAILED = ['NAO ENTREGUE', 'EXPIRADA', 'DELETADA', 'REJEITADA', 'CANCELADO', 'NUMERO INVALIDO', 'BLOQUEADA',
            'CARACTERES LIMITE EXCEDIDO', 'NUMERO BLOQUEADO', 'NUMERO FIXO', 'USUARIO SEM CREDITO', 'SPAM'].freeze

  def initialize(channel, event)
    @channel = channel
    @event = event.with_indifferent_access
  end

  def perform
    @phone = Sms::Providers::FluxService.normalize_phone(@event[:telefone])
    @status = ActiveSupport::Inflector.transliterate(@event[:status].to_s).upcase.strip
    return Sms::FluxReplyService.new(@channel, @event).perform if @status == 'RESPOSTA'

    @channel.with_lock do
      @outgoing = find_outgoing
      return if @outgoing && @outgoing.content_attributes['flux_phone'] != @phone

      update_status
    end
  rescue Sms::Providers::FluxService::Error
    Rails.logger.warn("Flux: callback with invalid phone for SMS channel #{@channel.id}")
  end

  private

  def find_outgoing
    messages = @channel.inbox.messages.where(message_type: [:outgoing, :template])
    match = @event[:idParceiro].to_s.match(/\AJRC-SMS-(\d+)\z/)
    message = messages.find_by(id: match[1]) if match
    message ||= messages.find_by(source_id: @event[:id].to_s) if @event[:id].present?
    message
  end

  def update_status
    return unless @outgoing

    @outgoing.with_lock do
      attrs = @outgoing.content_attributes
      previous_time = attrs['flux_status_at']
      return if previous_time.present? && @event[:data].to_s < previous_time
      return if @outgoing.delivered? || @outgoing.read?
      return if @outgoing.failed? && @status != 'ENTREGUE'

      status = if @status == 'ENTREGUE'
                 :delivered
               elsif FAILED.include?(@status)
                 :failed
               else
                 :sent
               end
      attrs = attrs.merge('flux_status' => @status, 'flux_status_at' => @event[:data], 'flux_id' => @event[:id].to_s)
      attrs['external_error'] = status == :failed ? "Flux: #{@status}" : nil
      @outgoing.update!(status: status, content_attributes: attrs)
    end
  end
end
