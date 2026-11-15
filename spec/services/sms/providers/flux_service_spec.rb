require 'rails_helper'

RSpec.describe Sms::Providers::FluxService do
  let(:channel) do
    create(:channel_sms, provider: 'flux', flux_account: 'test@example.invalid', flux_code: 'dummy-only',
                         provider_config: { 'send_type' => '2' })
  end
  let(:service) { described_class.new(channel) }
  let(:endpoint) { "#{described_class::API_BASE}/envio" }

  before do
    stub_request(:post, endpoint).to_return(status: 200, body: '{"codigo":"000","id":"1234567"}')
  end

  [159, 160].product(['a', 'é', '😀', '^', '€']).each do |length, character|
    it "sends #{length} occurrences of #{character} unchanged" do
      text = character * length
      expect(service.send_text('5511999999999', text)).to eq('1234567')
      expect(WebMock).to(have_requested(:post, endpoint).with { |request| JSON.parse(request.body)['msg'] == text })
    end
  end

  ['a', 'é', '😀', '^', '€'].each do |character|
    it "blocks 161 occurrences of #{character} before any HTTP request" do
      expect { service.send_text('5511999999999', character * 161) }
        .to(raise_error { |error| expect(error.class.name).to eq('Sms::Providers::FluxService::Error') })
      expect(WebMock).not_to have_requested(:post, endpoint)
    end
  end

  context 'when processing persisted messages' do
    let(:conversation) { create(:conversation, account: channel.account, inbox: channel.inbox) }
    let(:message) { create(:message, account: channel.account, inbox: channel.inbox, conversation: conversation, message_type: :outgoing) }

    it 'records acceptance as sent without claiming delivery and sends only once' do
      service.send_message('5511999999999', message)
      service.send_message('5511999999999', message.reload)
      expect(message.reload).to be_sent
      expect(message.source_id).to eq('1234567')
      expect(WebMock).to have_requested(:post, endpoint).once
    end

    it 'does not automatically repeat a rejected or unconfirmed attempt' do
      stub_request(:post, endpoint).to_return(status: 200, body: '175')
      service.send_message('5511999999999', message)
      service.send_message('5511999999999', message.reload)
      expect(message.reload).to be_failed
      expect(message.external_error).to eq('Flux 175: Mensagem classificada como spam')
      expect(WebMock).to have_requested(:post, endpoint).once
    end

    it 'keeps a callback received before the send response and never regresses delivery' do
      stub_request(:post, endpoint).to_return do
        event = { telefone: '5511999999999', id: '1234567', idParceiro: "JRC-SMS-#{message.id}",
                  status: 'ENTREGUE', data: '2026-11-15 12:00:00' }
        Sms::FluxCallbackService.new(channel, event).perform
        { status: 200, body: '{"codigo":"000","id":"1234567"}' }
      end
      service.send_message('5511999999999', message)
      expect(message.reload).to be_delivered
      expect(message.source_id).to eq('1234567')
    end
  end
end
