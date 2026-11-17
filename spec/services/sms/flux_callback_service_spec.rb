require 'rails_helper'

RSpec.describe Sms::FluxCallbackService do
  let(:channel) do
    create(:channel_sms, provider: 'flux', flux_account: 'test@example.invalid', flux_code: 'dummy-only',
                         provider_config: { 'send_type' => '2' })
  end
  let(:conversation) { create(:conversation, account: channel.account, inbox: channel.inbox) }
  let(:message) do
    create(:message, account: channel.account, inbox: channel.inbox, conversation: conversation, message_type: :outgoing,
                     source_id: '1234567', content_attributes: { flux_phone: '5511999999999' }).tap do |record|
      record.update!(content_attributes: record.content_attributes.merge('flux_partner_id' => "JRC-SMS-#{record.id}"))
    end
  end
  let(:event) do
    { 'telefone' => '5511999999999', 'id' => '1234567', 'idParceiro' => "JRC-SMS-#{message.id}",
      'status' => 'ENTREGUE', 'data' => '2026-11-15 12:00:00' }
  end

  it 'keeps API acceptance at sent until a delivery confirmation arrives' do
    described_class.new(channel, event.merge('status' => 'ENVIADA')).perform
    expect(message.reload).to be_sent
    expect(message.external_error).to be_nil
  end

  described_class::PENDING.each do |status|
    it "persists the pending provider state #{status} without claiming delivery" do
      described_class.new(channel, event.merge('status' => status)).perform
      expect(message.reload).to be_sent
      expect(message.content_attributes).to include('flux_status' => status, 'flux_status_at' => '2026-11-15T12:00:00Z')
      expect(message.external_error).to be_nil
    end
  end

  it 'marks only a matching delivery confirmation as delivered and emits an update' do
    expect(Rails.configuration.dispatcher).to receive(:dispatch).with('message.updated', anything, hash_including(message: message))
    described_class.new(channel, event).perform
    expect(message.reload).to be_delivered
    expect(message).not_to be_read
    expect(message.content_attributes).to include('flux_status' => 'ENTREGUE', 'flux_id' => '1234567')
  end

  described_class::FAILED.each do |status|
    it "preserves the original rejection #{status}" do
      described_class.new(channel, event.merge('status' => status)).perform
      expect(message.reload).to be_failed
      expect(message.external_error).to eq("Flux: #{status}")
      expect(message.content_attributes['flux_status']).to eq(status)
    end
  end

  it 'preserves accents and case in the provider reason' do
    described_class.new(channel, event.merge('status' => ' Número Inválido ')).perform
    expect(message.reload).to be_failed
    expect(message.external_error).to eq('Flux:  Número Inválido ')
  end

  it 'does not save or broadcast a duplicate callback' do
    described_class.new(channel, event).perform
    timestamp = message.reload.updated_at
    expect(Rails.configuration.dispatcher).not_to receive(:dispatch)
    described_class.new(channel, event).perform
    expect(message.reload.updated_at).to eq(timestamp)
  end

  it 'compares instants rather than lexicographic timestamps with offsets' do
    described_class.new(channel, event.merge('status' => 'ACEITA', 'data' => '2026-11-15T12:00:00Z')).perform
    described_class.new(channel, event.merge('data' => '2026-11-15T10:00:00-03:00')).perform
    expect(message.reload).to be_delivered
  end

  it 'ignores older events even when their local timestamp looks newer' do
    described_class.new(channel, event.merge('status' => 'ACEITA', 'data' => '2026-11-15T12:00:00Z')).perform
    described_class.new(channel, event.merge('status' => 'SPAM', 'data' => '2026-11-15T13:00:00+02:00')).perform
    expect(message.reload).to be_sent
  end

  it 'never regresses a delivery, including a newer failure' do
    described_class.new(channel, event).perform
    described_class.new(channel, event.merge('status' => 'SPAM', 'data' => '2026-11-15 13:00:00')).perform
    expect(message.reload).to be_delivered
    expect(message.external_error).to be_nil
  end

  it 'does not replace a failure by a pending state but allows a later real delivery' do
    described_class.new(channel, event.merge('status' => 'SPAM')).perform
    described_class.new(channel, event.merge('status' => 'ENVIADA', 'data' => '2026-11-15 13:00:00')).perform
    expect(message.reload).to be_failed
    described_class.new(channel, event.merge('data' => '2026-11-15 14:00:00')).perform
    expect(message.reload).to be_delivered
    expect(message.external_error).to be_nil
  end

  it 'correlates a callback arriving before the send response without losing the provider id' do
    message.update!(source_id: nil)
    described_class.new(channel, event).perform
    expect(message.reload).to be_delivered
    expect(message.source_id).to eq('1234567')
  end

  it 'resolves provider-only and partner-only identifiers' do
    described_class.new(channel, event.except('idParceiro').merge('status' => 'ACEITA')).perform
    described_class.new(channel, event.except('id').merge('data' => '2026-11-15 13:00:00')).perform
    expect(message.reload).to be_delivered
  end

  it 'recognizes an echoed partner id used as the source id' do
    message.update!(source_id: "JRC-SMS-#{message.id}")
    described_class.new(channel, event.except('idParceiro').merge('id' => message.source_id, 'status' => 'ACEITA')).perform
    described_class.new(channel, event).perform
    expect(message.reload).to be_delivered
    expect(message.source_id).to eq('1234567')
  end

  it 'handles an early callback for the existing Flux backup reservation' do
    message.update!(source_id: 'flux-fallback-reserved-999999999',
                    content_attributes: message.content_attributes.merge('flux_fallback_origin_message_id' => 999_999_999))
    described_class.new(channel, event).perform
    expect(message.reload).to be_delivered
    expect(message.source_id).to eq('1234567')
  end

  [
    { 'idParceiro' => 'JRC-SMS-999999999' }, { 'idParceiro' => 'unknown' },
    { 'id' => 'another-provider-id' }, { 'telefone' => '5511888888888' },
    { 'telefone' => 'invalid' }, { 'status' => 'READ' }, { 'data' => 'invalid' }
  ].each do |override|
    it "ignores an uncorrelated or unsupported callback #{override.keys.join(',')}=#{override.values.join(',')}" do
      described_class.new(channel, event.merge(override)).perform
      expect(message.reload).to be_sent
      expect(message.content_attributes).not_to have_key('flux_status')
    end
  end

  it 'does not associate another inbox in the same account' do
    other = create(:channel_sms, account: channel.account, provider: 'flux', flux_account: 'other@example.invalid', flux_code: 'dummy-only')
    described_class.new(other, event).perform
    expect(message.reload).to be_sent
  end

  it 'does not associate another account' do
    other = create(:channel_sms, provider: 'flux', flux_account: 'other@example.invalid', flux_code: 'dummy-only')
    described_class.new(other, event).perform
    expect(message.reload).to be_sent
  end

  it 'roundtrips the JSON store through Rails, API JSON and realtime without a migration' do
    message.update!(status: :failed, external_error: 'Flux: SPAM')
    raw_type = Message.connection.select_value("SELECT json_typeof(content_attributes) FROM messages WHERE id = #{message.id}")
    expect(raw_type).to eq('string')
    expect(message.reload.content_attributes).to be_a(Hash)
    expect(message.external_error).to eq('Flux: SPAM')
    expect(JSON.parse(message.push_event_data.to_json)['content_attributes']).to include('external_error' => 'Flux: SPAM')
  end
end
