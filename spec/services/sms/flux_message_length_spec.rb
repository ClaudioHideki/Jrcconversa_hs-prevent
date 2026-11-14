require 'rails_helper'

RSpec.describe Sms::FluxMessageLength do
  let(:channel) { build(:channel_sms, provider: 'flux', provider_config: { 'send_type' => '2' }) }

  [159, 160, 161].product(['a', 'é', '😀', '^', '€']).each do |length, character|
    it "preserves the backend count for #{length} occurrences of #{character}" do
      expect(described_class.excess(character * length, channel)).to eq([length - 160, 0].max)
    end
  end

  %w[1 2 7].each do |send_type|
    it "keeps 160 characters for type #{send_type}" do
      channel.provider_config['send_type'] = send_type
      expect(described_class.limit_for(channel)).to eq(160)
    end
  end

  it 'preserves the 1280-character SMS Carta limit' do
    channel.provider_config['send_type'] = '4'
    expect(described_class.limit_for(channel)).to eq(1280)
    expect(described_class.excess('a' * 1280, channel)).to eq(0)
    expect(described_class.excess('a' * 1281, channel)).to eq(1)
  end

  JSON.parse(Rails.root.join('spec/fixtures/flux_sms_lengths.json').read).each do |fixture|
    it "matches the canonical SMS fixture: #{fixture.fetch('name')}" do
      text = Messages::MarkdownRendererService.new(fixture.fetch('content'), 'Channel::Sms', channel).render
      expect(text).to eq(fixture.fetch('text'))
      expect(text.length).to eq(fixture.fetch('length'))
    end
  end
end
