class Sms::FluxMessageLength
  def self.limit_for(channel)
    channel.provider_config['send_type'].to_s == '4' ? 1280 : 160
  end

  # Preserve the Flux adapter's existing Ruby String#length (Unicode code points).
  # The provider has not documented GSM septets, UCS-2 or transliteration for this route.
  def self.excess(text, channel)
    [text.to_s.length - limit_for(channel), 0].max
  end

  def self.analyze(text, channel)
    { length: text.to_s.length, limit: limit_for(channel), excess: excess(text, channel), empty: text.blank? }
  end
end
