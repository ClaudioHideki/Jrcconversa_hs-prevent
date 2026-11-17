require 'rails_helper'

RSpec.describe 'New Flux SMS conversation preflight API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:channel) do
    create(:channel_sms, account: account, provider: 'flux', flux_account: 'test@example.invalid', flux_code: 'dummy-only',
                         provider_config: { 'send_type' => '2' })
  end
  let(:inbox) { channel.inbox }
  let(:contact) { create(:contact, account: account, name: 'Ana', phone_number: '+5511999999999') }
  let(:url) { "/api/v1/accounts/#{account.id}/conversations/sms_preview" }
  let(:headers) { agent.create_new_auth_token }
  let(:params) { { inbox_id: inbox.id, contact_id: contact.id, content: 'Olá 😀' } }

  before do
    create(:inbox_member, inbox: inbox, user: agent)
    contact
  end

  [159, 160, 161].product(['a', 'é', '😀', '^', '€', "\n"]).each do |length, character|
    it "uses the server representation for #{length} occurrences of #{character.inspect}" do
      params[:content] = character == "\n" ? "a#{character * (length - 2)}b" : character * length
      post url, params: params, headers: headers, as: :json
      expect(response).to have_http_status(:success)
      expect(response.parsed_body).to include('length' => length, 'limit' => 160, 'excess' => [length - 160, 0].max, 'valid' => length <= 160)
    end
  end

  JSON.parse(Rails.root.join('spec/fixtures/flux_sms_lengths.json').read).each do |fixture|
    it "reuses the canonical formatter: #{fixture.fetch('name')}" do
      post url, params: params.merge(content: fixture.fetch('content')), headers: headers, as: :json
      expect(response).to have_http_status(:success)
      expect(response.parsed_body['length']).to eq(fixture.fetch('length'))
    end
  end

  it 'expands the current contact and rejects 161 characters again on actual API creation' do
    contact.update!(name: 'a' * 161)
    post url, params: params.merge(content: '{{contact.name}}'), headers: headers, as: :json
    expect(response.parsed_body).to include('length' => 161, 'excess' => 1, 'valid' => false)
    expect do
      post "/api/v1/accounts/#{account.id}/conversations",
           params: params.merge(assignee_id: agent.id, message: { content: '{{contact.name}}' }), headers: headers, as: :json
    end.not_to(change { [Message.count, Conversation.count] })
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'matches Unicode links on the actual creation path' do
    text = "#{'a' * 131} [JRC](https://exemplo.com/ação)"
    post url, params: params.merge(content: text), headers: headers, as: :json
    expect(response.parsed_body).to include('length' => 160, 'valid' => true)
    expect(HTTParty).not_to receive(:post)
    post "/api/v1/accounts/#{account.id}/conversations",
         params: params.merge(assignee_id: agent.id, message: { content: text }), headers: headers, as: :json
    expect(response).to have_http_status(:success)
    expect(Message.outgoing.last.outgoing_content.length).to eq(160)
  end

  it 'does not create conversations, contacts, contact inboxes, messages or jobs during preview' do
    old_times = [account.reload.updated_at, contact.reload.updated_at, inbox.reload.updated_at]
    expect(HTTParty).not_to receive(:get)
    expect(HTTParty).not_to receive(:post)
    expect do
      post url, params: params, headers: headers, as: :json
    end.not_to(change { [Conversation.count, Contact.count, ContactInbox.count, Message.count] })
    expect(response).to have_http_status(:success)
    expect([account.reload.updated_at, contact.reload.updated_at, inbox.reload.updated_at]).to eq(old_times)
    expect(response.parsed_body.keys).to match_array(%w[length limit excess empty valid])
    expect(SendReplyJob).not_to have_been_enqueued
  end

  it 'uses the authenticated agent instead of caller-provided sender or assignment' do
    agent.update!(name: 'Alice')
    outsider = create(:user, account: create(:account), name: 'Foreign Agent')
    post url, params: params.merge(content: '{{agent.name}}', sender_id: outsider.id, assignee_id: outsider.id), headers: headers, as: :json
    expect(response.parsed_body).to include('length' => 5, 'valid' => true)
    expect(response.body).not_to include('Foreign', 'dummy-only', 'test@example.invalid')
  end

  %w[id display_id].each do |attribute|
    it "does not claim a definitive length for a future conversation #{attribute}" do
      post url, params: params.merge(content: "{{conversation.#{attribute}}}"), headers: headers, as: :json
      expect(response).to have_http_status(:success)
      expect(response.parsed_body).to eq('limit' => 160, 'valid' => false, 'reason' => 'conversation_not_created')
    end
  end

  it 'keeps the existing Liquid code-block protection' do
    post url, params: params.merge(content: '`{{conversation.id}}`'), headers: headers, as: :json
    expect(response.parsed_body).to include('length' => '{{conversation.id}}'.length, 'valid' => true)
  end

  it 'uses the actual existing conversation when the inbox reuses a single conversation' do
    inbox.update!(lock_to_single_conversation: true)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: contact.phone_number)
    conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
    post url, params: params.merge(content: '{{conversation.id}}'), headers: headers, as: :json
    expect(response.parsed_body).to include('length' => conversation.display_id.to_s.length, 'valid' => true)
  end

  it 'preserves the original Liquid drop string representation at the 160 boundary' do
    text = "#{'a' * (160 - ConversationDrop.name.length)}{{conversation}}"
    post url, params: params.merge(content: text), headers: headers, as: :json
    expect(response.parsed_body).to include('length' => 160, 'valid' => true)
    post "/api/v1/accounts/#{account.id}/conversations",
         params: params.merge(assignee_id: agent.id, message: { content: text }), headers: headers, as: :json
    expect(response).to have_http_status(:success)
    expect(Message.outgoing.last.outgoing_content.length).to eq(160)
  end

  it 'requires authentication' do
    post url, params: params, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'requires membership of the selected inbox' do
    InboxMember.where(inbox: inbox, user: agent).delete_all
    post url, params: params, headers: headers, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'rejects another account in the URL' do
    outsider = create(:user, account: create(:account), role: :administrator)
    post url, params: params, headers: outsider.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'does not resolve a foreign contact even for an account administrator' do
    foreign = create(:contact, account: create(:account), name: 'SECRET OTHER ACCOUNT')
    post url, params: params.merge(contact_id: foreign.id, content: '{{contact.name}}'), headers: headers, as: :json
    expect(response).to have_http_status(:not_found)
    expect(response.body).not_to include('SECRET')
  end

  it 'does not resolve an inbox from another account' do
    foreign = create(:channel_sms, account: create(:account)).inbox
    post url, params: params.merge(inbox_id: foreign.id), headers: headers, as: :json
    expect(response).to have_http_status(:not_found)
  end

  it 'rejects other SMS providers' do
    other = create(:channel_sms, account: account).inbox
    create(:inbox_member, inbox: other, user: agent)
    post url, params: params.merge(inbox_id: other.id), headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'preserves Carta 1280 instead of changing its modality' do
    channel.update!(provider_config: { 'send_type' => '4' })
    post url, params: params.merge(content: 'a' * 1280), headers: headers, as: :json
    expect(response.parsed_body).to include('limit' => 1280, 'length' => 1280, 'valid' => true)
    post url, params: params.merge(content: 'a' * 1281), headers: headers, as: :json
    expect(response.parsed_body).to include('excess' => 1, 'valid' => false)
  end

  [nil, 123, ['text'], { text: 'text' }, 'a' * 150_001].each do |content|
    it "rejects invalid content of type #{content.class} without sending" do
      post url, params: params.merge(content: content), headers: headers, as: :json
      expect(response).to have_http_status(:bad_request)
    end
  end
end
