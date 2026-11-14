require 'rails_helper'

RSpec.describe 'Flux SMS message limit API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:channel) do
    create(:channel_sms, account: account, provider: 'flux', flux_account: 'test@example.invalid', flux_code: 'dummy-only',
                         provider_config: { 'send_type' => '2' })
  end
  let(:inbox) { channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:url) { api_v1_account_conversation_messages_url(account_id: account.id, conversation_id: conversation.display_id) }

  before do
    create(:inbox_member, inbox: inbox, user: agent)
  end

  [159, 160, 161].product(['a', 'é', '😀', '^', '€']).each do |length, character|
    it "validates #{length} occurrences of #{character} through the authenticated API" do
      expect(HTTParty).not_to receive(:post)
      text = character * length
      expect do
        post url, params: { content: text, private: false }, headers: agent.create_new_auth_token, as: :json
      end.to change(conversation.messages, :count).by(length <= 160 ? 1 : 0)

      if length <= 160
        expect(response).to have_http_status(:success)
        expect(conversation.messages.last.content).to eq(text)
      else
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['error']).to include('160', '1')
      end
    end
  end

  it 'counts rendered links, including the destination URL' do
    post url, params: { content: "[x](https://example.com/#{'a' * 150})" }, headers: agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(conversation.messages).to be_empty
  end

  it 'allows private notes above 160 characters' do
    post url, params: { content: 'a' * 161, private: true }, headers: agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:success)
    expect(conversation.messages.last).to be_private
  end

  it 'validates after Liquid variable expansion' do
    conversation.contact.update!(name: 'a' * 161)
    post url, params: { content: '{{contact.name}}' }, headers: agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(conversation.messages).to be_empty
  end

  it 'preserves the SMS Carta modality' do
    channel.update!(provider_config: { 'send_type' => '4' })
    post url, params: { content: 'a' * 1280 }, headers: agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:success)
    post url, params: { content: 'a' * 1281 }, headers: agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'requires authentication' do
    post url, params: { content: 'test' }, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(conversation.messages).to be_empty
  end

  it 'requires inbox membership' do
    conversation
    InboxMember.where(inbox: inbox, user: agent).delete_all
    post url, params: { content: 'test' }, headers: agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(conversation.messages).to be_empty
  end

  it 'isolates other accounts' do
    outsider = create(:user, account: create(:account), role: :administrator)
    post url, params: { content: 'test' }, headers: outsider.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(conversation.messages).to be_empty
  end

  it 'exposes only the effective character limit to agents' do
    get api_v1_account_inbox_url(account_id: account.id, id: inbox.id), headers: agent.create_new_auth_token
    expect(response).to have_http_status(:success)
    expect(response.parsed_body['sms_character_limit']).to eq(160)
    expect(response.parsed_body).not_to have_key('provider_config')
    expect(response.body).not_to include('dummy-only', 'test@example.invalid', channel.flux_secrets['callback_token'])
  end
end
