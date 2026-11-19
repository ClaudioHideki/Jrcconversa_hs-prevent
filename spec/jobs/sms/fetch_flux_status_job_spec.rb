require 'rails_helper'

RSpec.describe Sms::FetchFluxStatusJob, type: :job do
  let(:channel) { create(:channel_sms, provider: 'flux', flux_account: 'job@example.invalid', flux_code: 'synthetic-only') }
  let(:conversation) { create(:conversation, account: channel.account, inbox: channel.inbox) }
  let(:message) do
    create(:message, account: channel.account, inbox: channel.inbox, conversation: conversation, message_type: :outgoing,
                     content_attributes: { flux_phone: '5511999999999' }).tap do |record|
      record.update!(content_attributes: record.content_attributes.merge('flux_partner_id' => "JRC-SMS-#{record.id}"))
    end
  end
  let(:lookup) { instance_double(Sms::FluxStatusLookup, perform: nil) }

  before { allow(Sms::FluxStatusLookup).to receive(:new).with(channel).and_return(lookup) }

  it 'queries once and schedules the next pending lookup after five minutes' do
    expect { described_class.perform_now(channel.id, message.id) }
      .to have_enqueued_job(described_class).with(channel.id, message.id, 1).at(a_value_within(3.seconds).of(5.minutes.from_now))
    expect(lookup).to have_received(:perform).once
    expect(described_class.log_arguments).to be(false)
  end

  it 'does not query twice inside the same minute, including duplicate jobs' do
    described_class.perform_now(channel.id, message.id)
    clear_enqueued_jobs
    described_class.perform_now(channel.id, message.id)
    expect(lookup).to have_received(:perform).once
    expect(described_class).not_to have_been_enqueued
  end

  it 'stops after a delivery callback' do
    message.update!(status: :delivered)
    described_class.perform_now(channel.id, message.id)
    expect(lookup).not_to have_received(:perform)
    expect(described_class).not_to have_been_enqueued
  end

  it 'stops after a final failure callback' do
    message.update!(status: :failed)
    described_class.perform_now(channel.id, message.id)
    expect(lookup).not_to have_received(:perform)
  end

  it 'stops scheduling after a successful 120 update' do
    allow(lookup).to receive(:perform) { message.update!(status: :delivered) }
    described_class.perform_now(channel.id, message.id)
    expect(message.reload).to be_delivered
    expect(described_class).not_to have_been_enqueued
  end

  it 'retries query errors with bounded spacing without changing the message' do
    allow(lookup).to receive(:perform).and_raise(Sms::FluxStatusLookup::Error, 'Synthetic 910')
    expect { described_class.perform_now(channel.id, message.id) }.to have_enqueued_job(described_class).with(channel.id, message.id, 1)
    expect(message.reload).to be_sent
  end

  it 'does not query or schedule beyond the attempt limit' do
    described_class.perform_now(channel.id, message.id, described_class::MAX_ATTEMPTS)
    expect(lookup).not_to have_received(:perform)
    expect(described_class).not_to have_been_enqueued
  end

  it 'runs the last allowed query without creating another attempt' do
    described_class.perform_now(channel.id, message.id, described_class::MAX_ATTEMPTS - 1)
    expect(lookup).to have_received(:perform).once
    expect(described_class).not_to have_been_enqueued
  end

  it 'does not query an inbox from another account' do
    other = create(:channel_sms, provider: 'flux', flux_account: 'other@example.invalid', flux_code: 'synthetic-only')
    described_class.perform_now(other.id, message.id)
    expect(lookup).not_to have_received(:perform)
  end

  it 'ignores private notes' do
    message.update!(private: true)
    described_class.perform_now(channel.id, message.id)
    expect(lookup).not_to have_received(:perform)
  end
end
