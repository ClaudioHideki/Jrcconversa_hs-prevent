require 'rails_helper'

RSpec.describe 'Flux mixed callback batches', type: :request do
  let(:channel) { create(:channel_sms, provider: 'flux', flux_account: 'lab@example.invalid', flux_code: 'synthetic-only') }
  let(:other_channel) { create(:channel_sms, provider: 'flux', flux_account: 'hs@example.invalid', flux_code: 'synthetic-only') }
  let(:token) { channel.flux_secrets.fetch('callback_token') }
  let(:other_token) { other_channel.flux_secrets.fetch('callback_token') }
  let(:conversation) { create(:conversation, account: channel.account, inbox: channel.inbox) }
  let(:other_conversation) { create(:conversation, account: other_channel.account, inbox: other_channel.inbox) }
  let(:message) do
    create(:message, account: channel.account, inbox: channel.inbox, conversation: conversation, message_type: :outgoing,
                     source_id: '991234', content_attributes: { flux_phone: '5511999999999' })
  end
  let(:other_message) do
    create(:message, account: other_channel.account, inbox: other_channel.inbox, conversation: other_conversation, message_type: :outgoing,
                     source_id: '997654', content_attributes: { flux_phone: '5511999999999' })
  end
  let(:event) { { telefone: '5511999999999', id: message.source_id, data: '2026-11-19 12:00:00', status: 'ENTREGUE', token: token } }
  let(:other_event) { event.merge(id: other_message.source_id, token: other_token, status: 'BLOQUEADA') }

  it 'authenticates each direct-array event and isolates accounts sharing the same recipient' do
    payload = [event, other_event]
    counts = [Message.count, Contact.count, Conversation.count]
    expect(HTTParty).not_to receive(:post)
    perform_enqueued_jobs(only: Webhooks::FluxEventsJob) do
      post '/f', params: payload, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq('OK')
    end
    expect(message.reload).to be_delivered
    expect(other_message.reload).to be_failed
    expect(other_message.content_attributes['flux_status']).to eq('BLOQUEADA')
    expect([Message.count, Contact.count, Conversation.count]).to eq(counts)
  end

  it 'groups only events authenticated for the same channel and strips credentials before enqueueing' do
    payload = [event, other_event, event]
    post '/f', params: payload, as: :json
    expect(response.body).to eq('OK')
    expect(Webhooks::FluxEventsJob).to have_been_enqueued.with(channel.id, [event.except(:token).stringify_keys] * 2)
    expect(Webhooks::FluxEventsJob).to have_been_enqueued.with(other_channel.id, [other_event.except(:token).stringify_keys])
    expect(Webhooks::FluxEventsJob).to have_been_enqueued.exactly(2).times
  end

  it 'handles the observed 199-event shape with two tokens without creating or sending messages' do
    payload = Array.new(198) { event } + [other_event]
    expect(HTTParty).not_to receive(:post)
    expect do
      perform_enqueued_jobs(only: Webhooks::FluxEventsJob) { post '/f', params: payload, as: :json }
    end.not_to change(Message, :count)
    expect(response.body).to eq('OK')
    expect(message.reload).to be_delivered
    expect(other_message.reload).to be_failed
  end

  it 'supports per-event authentication in the documented mensagens envelope' do
    post '/f', params: { mensagens: [event, other_event] }, as: :json
    expect(response.body).to eq('OK')
    expect(Webhooks::FluxEventsJob).to have_been_enqueued.with(channel.id, [event.except(:token).stringify_keys])
    expect(Webhooks::FluxEventsJob).to have_been_enqueued.with(other_channel.id, [other_event.except(:token).stringify_keys])
  end

  ['EM ANALISE', 'ENVIADA', 'BLOQUEADA', 'NAO ENTREGUE', 'ENTREGUE'].each do |status|
    it "processes #{status} in a direct array" do
      perform_enqueued_jobs(only: Webhooks::FluxEventsJob) do
        post '/f', params: [event.merge(status: status)], as: :json
      end
      expect(response.body).to eq('OK')
      expect(message.reload.content_attributes['flux_status']).to eq(status)
      expected = if status == 'ENTREGUE'
                   'delivered'
                 else
                   ['BLOQUEADA', 'NAO ENTREGUE'].include?(status) ? 'failed' : 'sent'
                 end
      expect(message.status).to eq(expected)
    end
  end

  it 'keeps two inboxes of one account separate' do
    other_channel.update!(account: channel.account)
    other_channel.inbox.update!(account: channel.account)
    other_conversation.update!(account: channel.account)
    other_message.update!(account: channel.account)
    perform_enqueued_jobs(only: Webhooks::FluxEventsJob) { post '/f', params: [event, other_event], as: :json }
    expect(response.body).to eq('OK')
    expect(message.reload).to be_delivered
    expect(other_message.reload).to be_failed
  end

  it 'does not update another channel message with a valid but unrelated token' do
    payload = [event.merge(token: other_token), other_event.merge(token: token)]
    perform_enqueued_jobs(only: Webhooks::FluxEventsJob) { post '/f', params: payload, as: :json }
    expect(response.body).to eq('OK')
    expect(message.reload).to be_sent
    expect(other_message.reload).to be_sent
  end

  [nil, '', 'unknown', ['invalid'], { 'token' => 'invalid' }, 'x' * 51].each do |invalid|
    it "rejects an entire batch containing an invalid #{invalid.class} token before enqueueing" do
      payload = [event, other_event.merge(token: invalid)]
      expect { post '/f', params: payload, as: :json }.not_to have_enqueued_job(Webhooks::FluxEventsJob)
      expect(response).to have_http_status(:unauthorized)
      expect(message.reload).to be_sent
      expect(other_message.reload).to be_sent
    end
  end

  it 'does not apply a global URL token to direct-array events missing their own token' do
    payload = [event, other_event.except(:token)]
    expect { post "/f?t=#{token}", params: payload, as: :json }.not_to have_enqueued_job(Webhooks::FluxEventsJob)
    expect(response).to have_http_status(:unauthorized)
  end

  [[], [nil], ['invalid'], [{ token: 'invalid' }, 42]].each do |invalid|
    it 'rejects a malformed direct array before enqueueing' do
      expect { post '/f', params: invalid, as: :json }.not_to have_enqueued_job(Webhooks::FluxEventsJob)
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  it 'accepts at most 1000 events and refuses an oversized batch without partial enqueueing' do
    post '/f', params: [event] * 1000, as: :json
    expect(response.body).to eq('OK')
    clear_enqueued_jobs
    expect { post '/f', params: [event] * 1001, as: :json }.not_to have_enqueued_job(Webhooks::FluxEventsJob)
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'preserves delivered after duplicate and older callbacks across mixed batches' do
    payload = [event, other_event]
    perform_enqueued_jobs(only: Webhooks::FluxEventsJob) do
      2.times { post '/f', params: payload, as: :json }
      post '/f', params: [event.merge(status: 'EM ANALISE', data: '2026-11-18 12:00:00')], as: :json
    end
    expect(response.body).to eq('OK')
    expect(message.reload).to be_delivered
    expect(other_message.reload).to be_failed
  end

  it 'returns failure instead of OK if a later channel enqueue fails and safely accepts the retry' do
    payload = [event, other_event]
    allow(Webhooks::FluxEventsJob).to receive(:perform_later).and_call_original
    allow(Webhooks::FluxEventsJob).to receive(:perform_later).with(other_channel.id, anything)
                                                             .and_raise(Redis::CannotConnectError, 'Synthetic queue outage')
    post '/f', params: payload, as: :json
    expect(response).to have_http_status(:internal_server_error)
    expect(response.body).not_to eq('OK')
    expect(Webhooks::FluxEventsJob).to have_been_enqueued.with(channel.id, anything)
    perform_enqueued_jobs(only: Webhooks::FluxEventsJob)
    expect(message.reload).to be_delivered
    allow(Webhooks::FluxEventsJob).to receive(:perform_later).with(other_channel.id, anything).and_call_original
    perform_enqueued_jobs(only: Webhooks::FluxEventsJob) { post '/f', params: payload, as: :json }
    expect(response.body).to eq('OK')
    expect(message.reload).to be_delivered
    expect(other_message.reload).to be_failed
  end

  it 'does not acknowledge an enqueue aborted by a job callback' do
    allow(Webhooks::FluxEventsJob).to receive(:perform_later).and_return(false)
    post '/f', params: [event], as: :json
    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).not_to eq('OK')
    expect(message.reload).to be_sent
  end

  it 'preserves isolated incoming replies and deduplicates retried mixed batches' do
    payload = [event.merge(status: 'RESPOSTA', resposta: 'Synthetic LAB reply'),
               other_event.merge(status: 'RESPOSTA', resposta: 'Synthetic HS reply')]
    expect(HTTParty).not_to receive(:post)
    expect do
      perform_enqueued_jobs(only: Webhooks::FluxEventsJob) do
        2.times { post '/f', params: payload, as: :json }
      end
    end.to change(Message, :count).by(2)
    expect(response.body).to eq('OK')
    expect(conversation.messages.incoming.pluck(:content)).to eq(['Synthetic LAB reply'])
    expect(other_conversation.messages.incoming.pluck(:content)).to eq(['Synthetic HS reply'])
  end

  it 'filters credentials and phones in Rails normalized direct-array parameters' do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter('_json' => [event.stringify_keys])
    expect(filtered['_json'].first.values_at('token', 'telefone')).to eq(['[FILTERED]', '[FILTERED]'])
    expect(Webhooks::FluxEventsJob.log_arguments).to be(false)
  end
end
