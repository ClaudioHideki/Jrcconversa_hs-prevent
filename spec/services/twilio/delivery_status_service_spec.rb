require 'rails_helper'

describe Twilio::DeliveryStatusService do
  let!(:account) { create(:account) }
  let!(:twilio_channel) do
    create(:channel_twilio_sms, account: account, account_sid: 'ACxxx',
                                inbox: create(:inbox, account: account, greeting_enabled: false))
  end
  let!(:contact) { create(:contact, account: account, phone_number: '+12345') }
  let(:contact_inbox) { create(:contact_inbox, source_id: '+12345', contact: contact, inbox: twilio_channel.inbox) }
  let!(:conversation) { create(:conversation, contact: contact, inbox: twilio_channel.inbox, contact_inbox: contact_inbox) }

  describe '#perform' do
    context 'when message delivery status is fired' do
      before do
        create(:message, account: account, inbox: twilio_channel.inbox, conversation: conversation, status: :sent,
                         source_id: 'SMd560ac79e4a4d36b3ce59f1f50471986')
      end

      it 'updates the message if the status is delivered' do
        params = {
          SmsSid: 'SMxx',
          From: '+12345',
          AccountSid: 'ACxxx',
          MessagingServiceSid: twilio_channel.messaging_service_sid,
          MessageSid: conversation.messages.last.source_id,
          MessageStatus: 'delivered'
        }

        described_class.new(params: params).perform
        expect(conversation.reload.messages.last.status).to eq('delivered')
      end

      it 'updates the message if the status is read' do
        params = {
          SmsSid: 'SMxx',
          From: '+12345',
          AccountSid: 'ACxxx',
          MessagingServiceSid: twilio_channel.messaging_service_sid,
          MessageSid: conversation.messages.last.source_id,
          MessageStatus: 'read'
        }

        described_class.new(params: params).perform
        expect(conversation.reload.messages.last.status).to eq('read')
      end

      it 'does not update the message if the status is not a support status' do
        params = {
          SmsSid: 'SMxx',
          From: '+12345',
          AccountSid: 'ACxxx',
          MessagingServiceSid: twilio_channel.messaging_service_sid,
          MessageSid: conversation.messages.last.source_id,
          MessageStatus: 'queued'
        }

        described_class.new(params: params).perform
        expect(conversation.reload.messages.last.status).to eq('sent')
      end

      it 'updates message status to failed if message status is undelivered' do
        params = {
          SmsSid: 'SMxx',
          From: '+12345',
          AccountSid: 'ACxxx',
          MessagingServiceSid: twilio_channel.messaging_service_sid,
          MessageSid: conversation.messages.last.source_id,
          MessageStatus: 'undelivered',
          ErrorCode: '30002',
          ErrorMessage: 'Account suspended'
        }

        described_class.new(params: params).perform
        expect(conversation.reload.messages.last.status).to eq('failed')
        expect(conversation.reload.messages.last.external_error).to eq('30002 - Account suspended')
      end

      it 'updates message status to failed and updates the error message if message status is failed' do
        params = {
          SmsSid: 'SMxx',
          From: '+12345',
          AccountSid: 'ACxxx',
          MessagingServiceSid: twilio_channel.messaging_service_sid,
          MessageSid: conversation.messages.last.source_id,
          MessageStatus: 'failed',
          ErrorCode: '30008',
          ErrorMessage: 'Unknown error'
        }

        described_class.new(params: params).perform
        expect(conversation.reload.messages.last.status).to eq('failed')
        expect(conversation.reload.messages.last.external_error).to eq('30008 - Unknown error')
      end

      it 'updates the error message if message status is undelivered and error message is not present' do
        params = {
          SmsSid: 'SMxx',
          From: '+12345',
          AccountSid: 'ACxxx',
          MessagingServiceSid: twilio_channel.messaging_service_sid,
          MessageSid: conversation.messages.last.source_id,
          MessageStatus: 'failed',
          ErrorCode: '30008'
        }

        described_class.new(params: params).perform
        expect(conversation.reload.messages.last.status).to eq('failed')
        expect(conversation.reload.messages.last.external_error).to eq('Error code: 30008')
      end

      context 'when updating persisted provider metadata' do
        let(:message) { conversation.messages.last }
        let(:params) do
          { MessagingServiceSid: twilio_channel.messaging_service_sid, MessageSid: message.source_id,
            MessageStatus: 'failed', ErrorCode: '30008', ErrorMessage: 'Unknown error' }
        end

        it 'keeps the error, code, fallback and other attributes together through persistence and realtime serialization' do
          metadata = { 'sms_fallback' => { 'state' => 'waiting', 'inbox_id' => 123 }, 'translations' => { 'pt' => 'Texto' } }
          message.update!(content_attributes: metadata)
          described_class.new(params: params).perform
          expect(message.reload.external_error).to eq('30008 - Unknown error')
          expect(message.content_attributes).to include(metadata.merge('external_error' => '30008 - Unknown error', 'twilio_error_code' => '30008'))
          expect(message.push_event_data[:content_attributes]).to include('external_error' => '30008 - Unknown error')
        end

        it 'retains a known failure reason when a later callback omits the error' do
          described_class.new(params: params).perform
          described_class.new(params: params.except(:ErrorCode, :ErrorMessage)).perform
          expect(message.reload.external_error).to eq('30008 - Unknown error')
          expect(message.content_attributes['twilio_error_code']).to eq('30008')
        end

        it 'clears only failure metadata after real delivery and ignores a late failure' do
          message.update!(content_attributes: { 'marker' => 'preserved' })
          described_class.new(params: params).perform
          described_class.new(params: params.merge(MessageStatus: 'delivered')).perform
          described_class.new(params: params).perform
          expect(message.reload).to be_delivered
          expect(message.external_error).to be_nil
          expect(message.content_attributes).to include('marker' => 'preserved', 'twilio_error_code' => nil)
        end

        it 'does not change a read message or repeat the update for a duplicate callback' do
          described_class.new(params: params).perform
          saved_at = message.reload.updated_at
          described_class.new(params: params).perform
          expect(message.reload.updated_at).to eq(saved_at)
          message.update!(status: :read, external_error: nil)
          described_class.new(params: params).perform
          expect(message.reload).to be_read
          expect(message.external_error).to be_nil
        end

        it 'does not update a message with the same source id in another inbox and account' do
          other = create(:message, source_id: message.source_id, content_attributes: { external_error: 'untouched' })
          described_class.new(params: params).perform
          expect(other.reload).to be_sent
          expect(other.external_error).to eq('untouched')
          expect(message.reload).to be_failed
        end
      end
    end
  end

  it 'logs a missing channel without the recipient phone number' do
    allow(Rails.logger).to receive(:warn)
    described_class.new(params: { AccountSid: 'unknown', From: '+5511999999999', MessageSid: 'SM-test' }).perform
    expect(Rails.logger).to have_received(:warn).with(include('lookup failed', 'from_present=true', 'message_sid=SM-test'))
    expect(Rails.logger).not_to have_received(:warn).with(include('5511999999999'))
  end
end
