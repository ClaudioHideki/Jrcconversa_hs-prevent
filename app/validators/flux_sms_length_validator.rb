class FluxSmsLengthValidator < ActiveModel::Validator
  def validate(record)
    return if record.private? || !(record.outgoing? || record.template?)

    channel = record.inbox.channel
    return unless channel.is_a?(Channel::Sms) && channel.flux?

    excess = Sms::FluxMessageLength.excess(record.outgoing_content, channel)
    return if excess.zero?

    record.errors.add(:content, :flux_sms_too_long, limit: Sms::FluxMessageLength.limit_for(channel), excess: excess)
  end
end
