require 'rails_helper'

RSpec.describe Sms::FluxStatusLookup do
  let(:channel) { create(:channel_sms, provider: 'flux', flux_account: 'status@example.invalid', flux_code: 'synthetic-only') }
  let(:conversation) { create(:conversation, account: channel.account, inbox: channel.inbox) }
  let(:message) do
    create(:message, account: channel.account, inbox: channel.inbox, conversation: conversation, message_type: :outgoing,
                     source_id: '991234', content_attributes: { flux_phone: '5511999999999' }).tap do |record|
      record.update!(content_attributes: record.content_attributes.merge('flux_partner_id' => "JRC-SMS-#{record.id}"))
    end
  end
  let(:row) do
    { id_mensagem: '991234', id_parceiro: "JRC-SMS-#{message.id}", id_status: 120,
      data_entrega: '19/11/2026 12:00:00', data_envio: '19/11/2026 11:59:00' }
  end
  let(:endpoint) { "#{Sms::Providers::FluxService::API_BASE}/integracao3.do" }

  before do
    stub_request(:get, endpoint).with(query: hash_including(type: 'C', id: "JRC-SMS-#{message.id}"))
                                .to_return(status: 200, body: { mensagens: [row] }.to_json)
  end

  it 'confirms 120 through the existing delivery processor and broadcasts without sending SMS' do
    expect(HTTParty).not_to receive(:post)
    expect(Rails.configuration.dispatcher).to receive(:dispatch).with('message.updated', anything, hash_including(message: message))
    described_class.new(channel).perform(message)
    expect(message.reload).to be_delivered
    expect(message.content_attributes['flux_status']).to eq('ENTREGUE')
    expect(message.content_attributes['flux_status_at']).to eq('2026-11-19T15:00:00Z')
  end

  { 110 => 'sent', 138 => 'sent', 130 => 'failed', 146 => 'failed', 150 => 'failed', 175 => 'failed' }.each do |code, status|
    it "maps documented API status #{code} without relying on the response description" do
      stub_request(:get, endpoint).with(query: hash_including(type: 'C'))
                                  .to_return(status: 200, body: { mensagens: [row.merge(id_status: code)] }.to_json)
      described_class.new(channel).perform(message)
      expect(message.reload.status).to eq(status)
      expect(message.content_attributes['flux_status']).to eq(described_class::STATUSES[code.to_s])
    end
  end

  [100, 999, nil].each do |code|
    it "does not invent a final state for unknown or pending code #{code.inspect}" do
      stub_request(:get, endpoint).with(query: hash_including(type: 'C'))
                                  .to_return(status: 200, body: { mensagens: [row.merge(id_status: code)] }.to_json)
      described_class.new(channel).perform(message)
      expect(message.reload).to be_sent
    end
  end

  [{ id_parceiro: 'JRC-SMS-other' }, { id_mensagem: 'different' }, { id_mensagem: '991235' }, { data_entrega: '' }].each do |invalid|
    it 'ignores mismatched identity or delivery without a valid timestamp' do
      stub_request(:get, endpoint).with(query: hash_including(type: 'C'))
                                  .to_return(status: 200, body: { mensagens: [row.merge(invalid)] }.to_json)
      described_class.new(channel).perform(message)
      expect(message.reload).to be_sent
    end
  end

  ['910', '{"codigo":"910"}', '{"codigo":"900"}', 'not json', '[]'].each do |body|
    it 'raises a sanitized error for rejected, rate limited or malformed responses' do
      stub_request(:get, endpoint).with(query: hash_including(type: 'C')).to_return(status: 200, body: body)
      expect { described_class.new(channel).perform(message) }.to raise_error(described_class::Error)
      expect(message.reload).to be_sent
    end
  end

  it 'leaves empty query results pending' do
    stub_request(:get, endpoint).with(query: hash_including(type: 'C')).to_return(status: 200, body: '{"mensagens":[]}')
    described_class.new(channel).perform(message)
    expect(message.reload).to be_sent
  end

  it 'does not query another account message' do
    other = create(:channel_sms, provider: 'flux', flux_account: 'other@example.invalid', flux_code: 'synthetic-only')
    described_class.new(other).perform(message)
    expect(WebMock).not_to have_requested(:get, endpoint).with(query: hash_including(type: 'C'))
  end

  it 'preserves delivery against duplicate queries and older callbacks' do
    described_class.new(channel).perform(message)
    Sms::FluxCallbackService.new(channel, telefone: '5511999999999', id: '991234', status: 'NAO ENTREGUE',
                                          data: '2026-11-18T12:00:00Z').perform
    described_class.new(channel).perform(message)
    expect(message.reload).to be_delivered
  end

  [500, 401, 429].each do |code|
    it "does not convert HTTP #{code} into delivery or non-delivery" do
      stub_request(:get, endpoint).with(query: hash_including(type: 'C')).to_return(status: code)
      expect { described_class.new(channel).perform(message) }.to raise_error(described_class::Error)
      expect(message.reload).to be_sent
    end
  end

  it 'does not expose network error URLs containing credentials' do
    stub_request(:get, endpoint).with(query: hash_including(type: 'C')).to_timeout
    expect { described_class.new(channel).perform(message) }.to raise_error(described_class::Error, 'Flux status: unavailable or invalid response')
  end
end
