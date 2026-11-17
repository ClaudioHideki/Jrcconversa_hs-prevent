require 'rails_helper'

RSpec.describe 'Flux delivery webhook', type: :request do
  let(:channel) { create(:channel_sms, provider: 'flux', flux_account: 'test@example.invalid', flux_code: 'dummy-only') }
  let(:token) { channel.flux_secrets.fetch('callback_token') }
  let(:conversation) { create(:conversation, account: channel.account, inbox: channel.inbox) }
  let(:message) do
    create(:message, account: channel.account, inbox: channel.inbox, conversation: conversation, message_type: :outgoing,
                     source_id: '1234567', content_attributes: { flux_phone: '5511999999999', external_error: nil })
  end
  let(:event) do
    { telefone: '5511999999999', id: message.source_id, data: '2026-11-15 12:00:00', status: 'ENTREGUE' }
  end

  it 'authenticates, queues and processes a real delivery without sending SMS' do
    expect(HTTParty).not_to receive(:post)
    perform_enqueued_jobs(only: Webhooks::FluxEventsJob) do
      post '/f', params: { t: token, mensagens: [event] }, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq('OK')
    end
    expect(message.reload).to be_delivered
  end

  it 'accepts the supported tokenCallback header on the long endpoint' do
    expect do
      post '/api/integrations/flux/callback', params: event, headers: { 'tokenCallback' => token }, as: :json
    end.to have_enqueued_job(Webhooks::FluxEventsJob).with(channel.id, [event.stringify_keys])
    expect(response.body).to eq('OK')
  end

  it 'rejects an invalid token without queueing events' do
    expect do
      post '/f?t=invalid', params: { mensagens: [event] }, as: :json
    end.not_to have_enqueued_job(Webhooks::FluxEventsJob)
    expect(response).to have_http_status(:unauthorized)
    expect(message.reload).to be_sent
  end

  [nil, ['invalid'], { 'unexpected' => 'invalid' }, 'x' * 51].each do |invalid_token|
    it "rejects a malformed #{invalid_token.class} token without an exception or queueing" do
      expect do
        post '/f', params: { t: invalid_token, mensagens: [event] }, as: :json
      end.not_to have_enqueued_job(Webhooks::FluxEventsJob)
      expect(response).to have_http_status(:unauthorized)
    end
  end

  it 'accepts tokenCallback in the JSON body and strips authentication fields from the job' do
    expect do
      post '/f', params: event.merge(tokenCallback: token), as: :json
    end.to have_enqueued_job(Webhooks::FluxEventsJob).with(channel.id, [event.stringify_keys])
    expect(response.body).to eq('OK')
  end

  it 'does not acknowledge success when the job queue raises an error' do
    allow(Webhooks::FluxEventsJob).to receive(:perform_later).and_raise(Redis::CannotConnectError, 'Synthetic queue outage')
    post '/f', params: { t: token, mensagens: [event] }, as: :json
    expect(response).to have_http_status(:internal_server_error)
    expect(response.body).not_to eq('OK')
    expect(message.reload).to be_sent
  end

  it 'rejects an oversized or empty batch after authentication' do
    post '/f', params: { t: token, mensagens: [] }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'filters callback tokens and recipient numbers from request logs' do
    expect(Webhooks::FluxEventsJob.log_arguments).to be(false)
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter('t' => token, 'tokenCallback' => token, 'mensagens' => [event.stringify_keys])
    expect(filtered['t']).to eq('[FILTERED]')
    expect(filtered['tokenCallback']).to eq('[FILTERED]')
    expect(filtered['mensagens'].first['telefone']).to eq('[FILTERED]')
  end

  it 'ignores an unknown id without inserting messages' do
    message
    expect do
      perform_enqueued_jobs(only: Webhooks::FluxEventsJob) do
        post '/f', params: { t: token, mensagens: [event.merge(id: 'unknown')] }, as: :json
      end
    end.not_to change(Message, :count)
    expect(message.reload).to be_sent
  end

  it 'exposes errors and changed delivery status through the authenticated messages API' do
    agent = create(:user, account: channel.account, role: :agent)
    create(:inbox_member, inbox: channel.inbox, user: agent)
    message.update!(status: :failed, external_error: 'Flux: SPAM')
    get "/api/v1/accounts/#{channel.account_id}/conversations/#{conversation.display_id}/messages", headers: agent.create_new_auth_token
    payload = response.parsed_body.fetch('payload').find { |item| item['id'] == message.id }
    expect(payload).to include('status' => 'failed', 'content_attributes' => hash_including('external_error' => 'Flux: SPAM'))
  end

  it 'refuses one-click Flux retry without clearing metadata or scheduling an external send' do
    agent = create(:user, account: channel.account, role: :agent)
    create(:inbox_member, inbox: channel.inbox, user: agent)
    message.update!(status: :failed, external_error: 'Flux: SPAM')
    attributes = message.reload.attributes
    expect do
      post "/api/v1/accounts/#{channel.account_id}/conversations/#{conversation.display_id}/messages/#{message.id}/retry",
           headers: agent.create_new_auth_token, as: :json
    end.not_to have_enqueued_job(SendReplyJob)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(message.reload.attributes).to eq(attributes)
  end
end
