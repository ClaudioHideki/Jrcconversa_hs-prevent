require 'rails_helper'

RSpec.describe 'Flux SMS exact preflight API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:channel) do
    create(:channel_sms, account: account, provider: 'flux', flux_account: 'test@example.invalid', flux_code: 'dummy-only',
                         provider_config: { 'send_type' => '2' })
  end
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox) }
  let(:url) { "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages/sms_preview" }

  before { create(:inbox_member, inbox: channel.inbox, user: agent) }

  JSON.parse(Rails.root.join('spec/fixtures/flux_sms_lengths.json').read).each do |fixture|
    it "returns the canonical representation count: #{fixture.fetch('name')}" do
      post url, params: { content: fixture.fetch('content') }, headers: agent.create_new_auth_token, as: :json
      expect(response).to have_http_status(:success)
      expect(response.parsed_body['length']).to eq(fixture.fetch('length'))
      expect(response.parsed_body['limit']).to eq(160)
      expect(response.parsed_body.keys).to match_array(%w[length limit excess empty valid])
    end
  end

  [159, 160, 161].product(['a', 'é', '😀', '^', '€']).each do |length, character|
    it "preflights #{length} occurrences of #{character}" do
      post url, params: { content: character * length }, headers: agent.create_new_auth_token, as: :json
      expect(response).to have_http_status(:success)
      expect(response.parsed_body).to include('length' => length, 'excess' => [length - 160, 0].max, 'valid' => length <= 160)
    end
  end

  it 'AUDIT: matches actual sending for the Unicode URL boundary' do
    text = "#{'a' * 131} [JRC](https://exemplo.com/ação)"
    headers = agent.create_new_auth_token
    post url, params: { content: text }, headers: headers, as: :json
    expect(response.parsed_body).to include('length' => 160, 'excess' => 0, 'valid' => true)
    post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages",
         params: { content: text, private: false }, headers: headers, as: :json
    expect(response).to have_http_status(:success)
    expect(conversation.messages.last.outgoing_content.length).to eq(160)
  end

  it 'AUDIT: expands Liquid with the same drops as actual sending' do
    conversation.contact.update!(name: 'a' * 161)
    headers = agent.create_new_auth_token
    post url, params: { content: '{{contact.name}}' }, headers: headers, as: :json
    expect(response.parsed_body).to include('length' => 161, 'excess' => 1, 'valid' => false)
    post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages",
         params: { content: '{{contact.name}}', private: false }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(conversation.messages).to be_empty
  end

  it 'uses the authenticated agent and preserves protected Liquid in code blocks' do
    agent.update!(name: 'Alice')
    post url, params: { content: '{{agent.name}} `{{contact.name}}`' }, headers: agent.create_new_auth_token, as: :json
    expect(response.parsed_body['length']).to eq('Alice {{contact.name}}'.length)
  end

  it 'counts Liquid filters through the existing Ruby renderer' do
    post url, params: { content: "{{ 'a' | append: 'bc' }}" }, headers: agent.create_new_auth_token, as: :json
    expect(response.parsed_body).to include('length' => 3, 'valid' => true)
  end

  it 'reports empty expansion without approximating the source length' do
    post url, params: { content: '{{contact.unknown}}' }, headers: agent.create_new_auth_token, as: :json
    expect(response.parsed_body).to include('length' => 0, 'empty' => true, 'valid' => false)
  end

  it 'does not persist, enqueue, contact Flux or change the conversation/contact' do
    contact_time = conversation.contact.reload.updated_at
    conversation_time = conversation.reload.updated_at
    expect(HTTParty).not_to receive(:post)
    expect(HTTParty).not_to receive(:get)
    expect do
      post url, params: { content: 'Olá 😀' }, headers: agent.create_new_auth_token, as: :json
    end.not_to change(Message, :count)
    expect(response).to have_http_status(:success)
    expect(conversation.reload.updated_at).to eq(conversation_time)
    expect(conversation.contact.reload.updated_at).to eq(contact_time)
    expect(SendReplyJob).not_to have_been_enqueued
  end

  it 'ignores foreign IDs and returns only count metadata' do
    conversation.contact.update!(name: 'Own')
    other = create(:contact, account: create(:account), name: 'FOREIGN-CONTACT-SECRET')
    post url, params: { content: '{{contact.name}}', contact_id: other.id, account_id: other.account_id, sender_id: other.id },
              headers: agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:success)
    expect(response.parsed_body['length']).to eq(3)
    expect(response.body).not_to include('FOREIGN', 'dummy-only', 'test@example.invalid')
  end

  it 'requires authentication' do
    post url, params: { content: '{{contact.name}}' }, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'requires the current inbox permissions' do
    conversation
    InboxMember.where(inbox: channel.inbox, user: agent).delete_all
    post url, params: { content: '{{contact.name}}' }, headers: agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'isolates other accounts' do
    outsider = create(:user, account: create(:account), role: :administrator)
    post url, params: { content: '{{contact.name}}' }, headers: outsider.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'does not apply preflight to other SMS providers' do
    other_channel = create(:channel_sms, account: account)
    other_conversation = create(:conversation, account: account, inbox: other_channel.inbox)
    create(:inbox_member, inbox: other_channel.inbox, user: agent)
    post "/api/v1/accounts/#{account.id}/conversations/#{other_conversation.display_id}/messages/sms_preview",
         params: { content: 'text' }, headers: agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'preserves the Carta limit' do
    channel.update!(provider_config: { 'send_type' => '4' })
    post url, params: { content: 'a' * 1280 }, headers: agent.create_new_auth_token, as: :json
    expect(response.parsed_body).to include('limit' => 1280, 'length' => 1280, 'valid' => true)
  end
end
