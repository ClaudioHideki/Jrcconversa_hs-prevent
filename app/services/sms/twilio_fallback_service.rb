class Sms::TwilioFallbackService
  WAIT = 60.seconds
  ATTRIBUTE = 'sms_fallback'.freeze

  def self.schedule(message, sent_body = nil)
    channel = message.inbox.channel
    return unless channel.is_a?(Channel::TwilioSms) && channel.flux_fallback_inbox.present?
    return if message.private? || message.content_type == 'voice_call' || message.deleted

    due_at = WAIT.from_now
    message.with_lock do
      return if message.content_attributes[ATTRIBUTE].present? || message.delivered? || message.read?

      message.update!(content_attributes: message.content_attributes.merge(ATTRIBUTE => {
                        'state' => 'waiting', 'inbox_id' => channel.flux_fallback_inbox_id.to_i, 'twilio_sid' => message.source_id,
                        'due_at' => due_at.iso8601, 'text' => sent_body.presence || message.outgoing_content,
                        'phone' => message.conversation.contact_inbox.source_id.to_s.delete_prefix('whatsapp:'),
                        'template' => message.additional_attributes['template_params'].present?
                      }))
    end
    enqueue_pending(message)
  end

  def self.enqueue_pending(message)
    data = message.content_attributes[ATTRIBUTE]
    return unless data && data['state'] == 'waiting'

    Sms::TwilioFallbackJob.set(wait_until: Time.iso8601(data.fetch('due_at'))).perform_later(message.id)
  end

  def self.sync_status(fallback_message)
    origin_id = fallback_message.content_attributes['flux_fallback_origin_message_id']
    origin = Message.find_by(id: origin_id, account_id: fallback_message.account_id)
    return unless origin

    origin.with_lock do
      data = origin.content_attributes[ATTRIBUTE]
      return unless data && data['message_id'] == fallback_message.id && data['inbox_id'] == fallback_message.inbox_id
      return if %w[delivered read].include?(data['state']) && !fallback_message.read?

      state = fallback_message.status
      state = 'sending' if fallback_message.source_id.to_s.start_with?('flux-fallback-reserved-') && !fallback_message.failed?
      origin.update!(content_attributes: origin.content_attributes.merge(ATTRIBUTE => data.merge(
                       'state' => state, 'error' => fallback_message.external_error,
                       'updated_at' => Time.current.iso8601
                     )))
    end
  end

  def initialize(message)
    @message = message
    @channel = message.inbox.channel
  end

  def perform
    return unless @channel.is_a?(Channel::TwilioSms)
    return unless data['state'] == 'waiting'

    due_at = Time.iso8601(data.fetch('due_at'))
    if due_at > Time.current
      Sms::TwilioFallbackJob.set(wait_until: due_at).perform_later(@message.id)
      return
    end

    check_twilio_status unless @message.delivered? || @message.read? || @message.source_id != data['twilio_sid']
    fallback_message = prepare_fallback
    return unless fallback_message

    send_fallback(fallback_message)
  end

  private

  def data
    @message.content_attributes[ATTRIBUTE] || {}
  end

  def check_twilio_status
    @twilio_message = @channel.client.messages(@message.source_id).fetch
    Twilio::DeliveryStatusService.new(params: {
      AccountSid: @channel.account_sid, From: @channel.phone_number,
      MessagingServiceSid: @channel.messaging_service_sid,
      MessageSid: @message.source_id, MessageStatus: @twilio_message.status,
      ErrorCode: @twilio_message.error_code, ErrorMessage: @twilio_message.error_message
    }).perform
  rescue Twilio::REST::TwilioError, Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, Faraday::Error
    # A failed lookup is not proof of delivery. Recheck the latest local receipt under the lock below.
    @check_failed = true
  end

  def prepare_fallback
    @message.with_lock do
      next unless data['state'] == 'waiting'

      target = @channel.reload.flux_fallback_inbox
      reason = skip_reason(target)
      if reason
        update_data('state' => 'skipped', 'reason' => reason)
        next
      end

      phone = Sms::Providers::FluxService.normalize_phone(data['phone'])
      text = @twilio_message&.body.presence || data['text']
      limit = target.channel.provider_config['send_type'].to_s == '4' ? 1280 : 160
      if text.blank? || text.length > limit
        update_data('state' => 'skipped', 'reason' => 'text_limit')
        next
      end

      conversation = fallback_conversation(target, phone)
      # A persisted source ID stops the generic SendReplyJob from sending this message.
      # Only this claimed attempt may call Flux; a worker retry must never resend it.
      fallback_message = conversation.messages.create!(
        account_id: @message.account_id, inbox: target, message_type: :outgoing, content: text,
        source_id: "flux-fallback-reserved-#{@message.id}",
        content_attributes: { flux_fallback_origin_message_id: @message.id, flux_phone: phone }
      )
      update_data('state' => 'sending', 'message_id' => fallback_message.id,
                  'conversation_display_id' => conversation.display_id, 'check_failed' => @check_failed == true)
      fallback_message
    end
  rescue Sms::Providers::FluxService::Error
    @message.with_lock { update_data('state' => 'skipped', 'reason' => 'invalid_phone') if data['state'] == 'waiting' }
    nil
  end

  def skip_reason(target)
    return 'delivered' if @message.delivered? || @message.read?
    return 'disabled' unless target && target.id == data['inbox_id']
    return 'deleted' if @message.deleted || @message.private?
    return 'primary_changed' if @message.source_id != data['twilio_sid']
    return 'opted_out' if %w[21610 63014 63033 63050].include?(@message.content_attributes['twilio_error_code'])
    return 'attachments' if @message.attachments.exists? || @twilio_message&.num_media.to_i.positive?
    return 'template_body' if data['template'] && @twilio_message&.body.blank?

    nil
  end

  def fallback_conversation(target, phone)
    contact_inbox = target.contact_inboxes.find_by(source_id: "+#{phone}") || ContactInbox.create!(
      inbox: target, contact: @message.conversation.contact, source_id: "+#{phone}"
    )
    conversations = contact_inbox.conversations
    conversations = conversations.where.not(status: :resolved) unless target.lock_to_single_conversation
    conversations.last || Conversation.create!(
      account_id: target.account_id, inbox: target, contact_inbox: contact_inbox, contact: contact_inbox.contact
    )
  end

  def send_fallback(fallback_message)
    partner_id = "JRC-SMS-#{fallback_message.id}"
    fallback_message.update!(content_attributes: fallback_message.content_attributes.merge('flux_partner_id' => partner_id))
    provider_id = Sms::Providers::FluxService.new(fallback_message.inbox.channel).send_text(
      data['phone'], fallback_message.content, partner_id: partner_id
    )
    fallback_message.with_lock { fallback_message.update!(source_id: provider_id) }
  rescue Sms::Providers::FluxService::Error => e
    fallback_message.with_lock do
      fallback_message.update!(status: :failed, external_error: e.message) unless fallback_message.delivered? || fallback_message.read?
    end
  end

  def update_data(changes)
    @message.update!(content_attributes: @message.content_attributes.merge(ATTRIBUTE => data.merge(changes).merge(
                       'updated_at' => Time.current.iso8601
                     )))
  end
end
