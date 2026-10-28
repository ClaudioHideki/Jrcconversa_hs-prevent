class Sms::FluxReplyService
  def initialize(channel, event, source: :callback)
    @channel = channel
    @event = event.with_indifferent_access
    @source = source
  end

  def self.received_time(value, source: :callback)
    raw = value.to_s.strip
    zone = Time.find_zone!(source == :api ? 'America/Sao_Paulo' : ENV.fetch('FLUX_CALLBACK_TIME_ZONE', 'UTC'))
    begin
      return Time.iso8601(raw.tr(' ', 'T')).utc if source == :callback && raw.match?(/(?:Z|[+-]\d{2}:?\d{2})\z/)

      format = source == :api ? '%d/%m/%Y %H:%M:%S' : '%Y-%m-%d %H:%M:%S'
      parsed = zone.strptime(raw, format)
      parsed.utc if parsed.strftime(format) == raw
    rescue ArgumentError, TypeError
      nil
    end
  end

  def perform
    return :ignored if @event[:resposta].blank?

    @channel.with_lock do
      next :ignored if @source == :api && !@channel.flux_mo_polling_enabled?

      @outgoing = find_outgoing
      next :ignored if @source == :api && !@outgoing

      @phone = Sms::Providers::FluxService.normalize_phone(@event[:telefone])
      next :ignored if @outgoing && @outgoing.content_attributes['flux_phone'] != @phone

      @partner_id = @outgoing ? "JRC-SMS-#{@outgoing.id}" : @event[:idParceiro].presence || @event[:id].to_s
      @time = self.class.received_time(@event[:data], source: @source)
      @key = Digest::SHA256.hexdigest([@partner_id, @phone, @time&.iso8601, @event[:resposta]].to_json) if @time
      @mo_id = @event[:idResposta].to_s.presence
      @mo_id = nil unless @mo_id&.match?(/\A\d+\z/)
      existing = find_existing
      if existing
        metadata = existing.content_attributes.merge(identity_attributes)
        existing.update!(content_attributes: metadata) if metadata != existing.content_attributes
        next :matched
      end

      conversation = @outgoing&.conversation || reply_conversation
      conversation.update!(status: :open) if conversation.resolved?
      attributes = {
        account_id: @channel.account_id, inbox_id: @channel.inbox.id,
        message_type: :incoming, sender: conversation.contact, content: @event[:resposta], source_id: source_id,
        content_attributes: {
          flux_id: @event[:id].to_s, flux_partner_id: @partner_id, flux_received_at: @event[:data], flux_reply_source: @source.to_s
        }.merge(identity_attributes)
      }
      conversation.messages.create!(attributes)
      :created
    end
  end

  private

  def find_outgoing
    messages = @channel.inbox.messages.where(account_id: @channel.account_id, message_type: [:outgoing, :template])
    match = @event[:idParceiro].to_s.match(/\AJRC-SMS-(\d+)\z/)
    message = messages.find_by(id: match[1]) if match
    message ||= messages.find_by(source_id: @event[:id].to_s) if @source == :callback && @event[:id].present?
    message
  end

  def find_existing
    scope = @channel.inbox.messages.where(account_id: @channel.account_id, message_type: :incoming)
    existing = scope.find_by("content_attributes ->> 'flux_mo_id' = ?", @mo_id) if @mo_id
    return existing if existing

    existing = scope.find_by(source_id: legacy_source_id) if @source == :callback
    existing = nil if existing && @mo_id && existing.content_attributes['flux_mo_id'].present? &&
                      existing.content_attributes['flux_mo_id'] != @mo_id
    return existing if existing
    return unless @key

    candidates = scope.where(content: @event[:resposta]).where('source_id LIKE ?', 'flux-mo-%')
    candidates = candidates.where(conversation_id: @outgoing.conversation_id) if @outgoing
    candidates.detect do |candidate|
      attrs = candidate.content_attributes
      next false if @mo_id && attrs['flux_mo_id'].present? && attrs['flux_mo_id'] != @mo_id
      next true if attrs['flux_reply_key'] == @key
      next false if attrs['flux_partner_id'].present? && attrs['flux_partner_id'] != @partner_id

      previous_source = attrs['flux_reply_source'] == 'api' ? :api : :callback
      self.class.received_time(attrs['flux_received_at'], source: previous_source)&.iso8601 == @time.iso8601
    end
  end

  def identity_attributes
    {}.tap do |attrs|
      attrs['flux_reply_key'] = @key if @key
      attrs['flux_reply_at'] = @time.iso8601 if @time
      attrs['external_created_at'] = @time.iso8601 if @time && @source == :api
      attrs['flux_mo_id'] = @mo_id if @mo_id
    end
  end

  def source_id
    return "flux-mo-id-#{@channel.id}-#{@mo_id}" if @mo_id

    @key ? "flux-mo-#{@key}" : legacy_source_id
  end

  def legacy_source_id
    fingerprint = [@event[:id], @event[:idParceiro], @phone, @event[:data], @event[:resposta]].map(&:to_s)
    "flux-mo-#{Digest::SHA256.hexdigest(fingerprint.to_json)}"
  end

  def reply_conversation
    phone = "+#{@phone}"
    contact_inbox = ContactInboxWithContactBuilder.new(
      inbox: @channel.inbox, source_id: phone, contact_attributes: { phone_number: phone, name: phone }
    ).perform
    conversations = contact_inbox.conversations
    conversations = conversations.where.not(status: :resolved) unless @channel.inbox.lock_to_single_conversation
    conversations.last || Conversation.create!(
      account_id: @channel.account_id, inbox_id: @channel.inbox.id,
      contact_id: contact_inbox.contact_id, contact_inbox_id: contact_inbox.id
    )
  end
end
