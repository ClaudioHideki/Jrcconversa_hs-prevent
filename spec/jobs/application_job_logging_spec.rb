require 'rails_helper'

RSpec.describe ApplicationJob do
  let(:output) { StringIO.new }
  let(:logger) { ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(output)) }
  let(:secret) { 'PRIVATE-JOB-ARGUMENT-SENTINEL' }
  let(:payload) { { 'content' => secret, 'phone_number' => '5511999999999', 'external_error' => secret, 'token' => secret } }

  around do |example|
    previous_job_logger = ActiveJob::Base.logger
    previous_rails_logger = Rails.logger
    ActiveJob::Base.logger = logger
    Rails.logger = logger
    example.run
  ensure
    ActiveJob::Base.logger = previous_job_logger
    Rails.logger = previous_rails_logger
  end

  it 'keeps broadcast payloads intact while logging enqueue, start and completion without streams or content' do
    allow(ActionCable.server).to receive(:broadcast)
    job = nil
    perform_enqueued_jobs(only: ActionCableBroadcastJob) do
      job = ActionCableBroadcastJob.perform_later([secret], 'message.updated', payload)
    end
    expect(ActionCable.server).to have_received(:broadcast).with(secret, event: 'message.updated', data: payload)
    expect(output.string).to include(
      'Enqueued ActionCableBroadcastJob', 'Performing ActionCableBroadcastJob', 'Performed ActionCableBroadcastJob', 'critical', job.job_id
    )
    expect(output.string).not_to include(secret, '5511999999999', 'with arguments:')
  end

  it 'keeps dispatcher arguments intact and logs failures without dumping their values' do
    timestamp = Time.current
    allow(Rails.configuration.dispatcher.async_dispatcher).to receive(:publish_event).and_raise(StandardError, 'Synthetic dispatch failure')
    job = EventDispatcherJob.perform_later('message.updated', timestamp, payload)
    expect { job.perform_now }.to raise_error(StandardError, 'Synthetic dispatch failure')
    expect(Rails.configuration.dispatcher.async_dispatcher).to have_received(:publish_event).with('message.updated', timestamp, payload)
    expect(output.string).to include(job.job_id, 'Error performing EventDispatcherJob', 'StandardError', 'critical')
    expect(output.string).not_to include(secret, '5511999999999', 'with arguments:')
  end

  it 'discards an unavailable GlobalID without printing the serialized payload' do
    job = EventDispatcherJob.new('message.updated', Time.current, payload)
    serialized = job.serialize
    serialized['arguments'] << { '_aj_globalid' => 'gid://chatwoot/Contact/999999999' }
    expect { ActiveJob::Base.execute(serialized) }.not_to raise_error
    expect(output.string).to include('ActiveJob::DeserializationError', job.job_id, 'critical', 'Skipping EventDispatcherJob')
    expect(output.string).not_to include(secret, '5511999999999', '_aj_globalid')
  end

  it 'keeps argument logging enabled for other jobs' do
    expect(described_class.log_arguments?).to be(true)
    expect(SendReplyJob.log_arguments?).to be(true)
    expect(Webhooks::FluxEventsJob.log_arguments?).to be(false)
  end
end
