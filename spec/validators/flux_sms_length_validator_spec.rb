require 'rails_helper'

RSpec.describe FluxSmsLengthValidator do
  let(:channel) do
    create(:channel_sms, provider: 'flux', flux_account: 'test@example.invalid', flux_code: 'dummy-only',
                         provider_config: { 'send_type' => '2' })
  end
  let(:conversation) { create(:conversation, inbox: channel.inbox, account: channel.account) }

  it 'does not reject inbound messages' do
    message = build(:message, conversation: conversation, account: channel.account, content: 'a' * 161, message_type: :incoming)
    expect(message).to be_valid
  end

  it 'allows status updates on old oversized messages' do
    message = create(:message, conversation: conversation, account: channel.account, content: 'old message', message_type: :outgoing)
    message.update!(content: 'a' * 161)
    expect { message.update!(status: :delivered) }.not_to raise_error
    expect(message.reload).to be_delivered
  end

  it 'leaves other SMS providers unchanged' do
    other_channel = create(:channel_sms)
    other_conversation = create(:conversation, inbox: other_channel.inbox, account: other_channel.account)
    message = build(:message, conversation: other_conversation, account: other_channel.account, content: 'a' * 161, message_type: :outgoing)
    expect(message).to be_valid
  end

  it 'leaves other channels unchanged' do
    message = build(:message, content: 'a' * 161, message_type: :outgoing)
    expect(message).to be_valid
  end
end
