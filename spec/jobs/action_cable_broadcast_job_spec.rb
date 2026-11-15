require 'rails_helper'

RSpec.describe ActionCableBroadcastJob do
  it 'keeps the original message payload and audience' do
    data = { 'id' => 1, 'status' => 'delivered', 'content_attributes' => { 'flux_status' => 'ENTREGUE' } }
    expect(ActionCable.server).to receive(:broadcast).with('authorized-stream', hash_including(event: 'message.updated', data: data))
    described_class.perform_now(['authorized-stream'], 'message.updated', data)
  end

  it 'does not broadcast without recipients' do
    expect(ActionCable.server).not_to receive(:broadcast)
    described_class.perform_now([], 'message.updated', {})
  end

  it 'keeps conversation events current while preserving account scope' do
    conversation = create(:conversation, status: :open)
    data = { account_id: conversation.account_id, id: conversation.display_id, status: 'resolved' }
    expect(ActionCable.server).to receive(:broadcast).with(
      'authorized-stream', hash_including(event: 'conversation.updated', data: hash_including(account_id: conversation.account_id, status: 'open'))
    )
    described_class.perform_now(['authorized-stream'], 'conversation.updated', data)
  end
end
