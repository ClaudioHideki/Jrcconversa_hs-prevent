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
end
