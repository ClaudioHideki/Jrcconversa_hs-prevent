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

    it 'schedules a status lookup after acceptance without claiming delivery' do
      expect { service.send_message('5511999999999', message) }
        .to have_enqueued_job(Sms::FetchFluxStatusJob).with(channel.id, message.id)
      expect(message.reload).to be_sent
    end

    it 'recovers a status enqueue failure without sending the SMS again' do
      scheduler = instance_double(ActiveJob::ConfiguredJob)
      allow(scheduler).to receive(:perform_later).and_raise(Redis::CannotConnectError, 'Synthetic queue failure')
      allow(Sms::FetchFluxStatusJob).to receive(:set).and_return(scheduler)
      expect { service.send_message('5511999999999', message) }.to raise_error(Redis::CannotConnectError)
      allow(Sms::FetchFluxStatusJob).to receive(:set).and_call_original
      expect { service.send_message('5511999999999', message.reload) }
        .to have_enqueued_job(Sms::FetchFluxStatusJob).with(channel.id, message.id)
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

  context 'when configuring callback routing' do
    it 'uses a dedicated short origin without changing the main URL or the secret token' do
      with_modified_env FRONTEND_URL: 'https://jrcconversas-lab.jrcws.cloud', FLUX_CALLBACK_BASE_URL: 'https://s.jrcws.cloud/' do
        token = channel.flux_secrets.fetch('callback_token')
        service.send_text('5511999999999', 'Callback routing')
        expect(WebMock).to(have_requested(:post, endpoint).with do |request|
          body = JSON.parse(request.body)
          body['urlCallback'] == 'https://s.jrcws.cloud/f' && body['tokenCallback'] == token
        end)
        expect(ENV.fetch('FRONTEND_URL')).to eq('https://jrcconversas-lab.jrcws.cloud')
        expect(channel.reload.flux_secrets.fetch('callback_token')).to eq(token)
      end
    end

    it 'preserves the existing origin when the override is empty' do
      with_modified_env FRONTEND_URL: 'https://a.co/', FLUX_CALLBACK_BASE_URL: '' do
        expect(channel.flux_callback_url).to eq('https://a.co/f')
        expect(service.send_text('5511999999999', 'Legacy routing')).to eq('1234567')
      end
    end

    it 'uses the original lab origin within 50 characters without a URL secret' do
      with_modified_env FRONTEND_URL: 'https://jrcconversas-lab.jrcws.cloud', FLUX_CALLBACK_BASE_URL: '' do
        expect(channel.flux_callback_url).to eq('https://jrcconversas-lab.jrcws.cloud/f')
        expect(channel.flux_callback_url.bytesize).to eq(38)
        expect(service.send_text('5511999999999', 'Body authentication')).to eq('1234567')
      end
    end

    it 'accepts an authenticated callback of exactly 50 characters' do
      with_modified_env FLUX_CALLBACK_BASE_URL: "https://#{'a' * 36}.com" do
        expect(channel.flux_callback_url.length).to eq(50)
        expect(service.send_text('5511999999999', 'Boundary')).to eq('1234567')
      end
    end

    ["https://#{'a' * 37}.com",
     'https://u:p@a.co', 'https://a.co/#fragment', 'https://a.co/?other=value', 'https://['].each do |base|
      it "rejects unsupported callback configuration before any HTTP request: #{base}" do
        with_modified_env FLUX_CALLBACK_BASE_URL: base do
          expect { service.send_text('5511999999999', 'Invalid callback') }
            .to(raise_error { |error| expect(error.class.name).to eq('Sms::Providers::FluxService::Error') })
          expect(WebMock).not_to have_requested(:post, endpoint)
        end
      end
    end

    it 'records a configuration failure without sending, truncating content or revealing the token' do
      conversation = create(:conversation, account: channel.account, inbox: channel.inbox)
      message = create(:message, account: channel.account, inbox: channel.inbox, conversation: conversation,
                                 message_type: :outgoing, content: 'Preserve this draft content')
      with_modified_env FLUX_CALLBACK_BASE_URL: "https://#{'a' * 37}.com" do
        service.send_message('5511999999999', message)
        expect(message.reload).to be_failed
        expect(message.content).to eq('Preserve this draft content')
        expect(message.external_error).to include('FLUX_CALLBACK_BASE_URL')
        expect(message.external_error).not_to include(channel.flux_secrets.fetch('callback_token'))
        expect(WebMock).not_to have_requested(:post, endpoint)
      end
    end
  end
end
