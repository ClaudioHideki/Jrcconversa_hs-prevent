require 'rails_helper'

RSpec.describe SensitiveJobErrorLogger do
  let(:output) { StringIO.new }
  let(:config) { Sidekiq::Config.new.tap { |settings| settings.logger = Logger.new(output) } }
  let(:secret) { 'PRIVATE-SIDEKIQ-PAYLOAD-SENTINEL' }
  let(:exception) { StandardError.new(secret).tap { |error| error.set_backtrace(['app/jobs/example.rb:10:in perform']) } }
  let(:job) do
    { 'wrapped' => 'ActionCableBroadcastJob', 'class' => 'ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper',
      'jid' => 'safe-jid', 'queue' => 'critical', 'retry_count' => 2,
      'args' => [{ 'job_id' => 'safe-job-id', 'arguments' => [[secret], { 'phone' => '5511999999999', 'content' => secret }] }] }
  end

  %w[ActionCableBroadcastJob EventDispatcherJob Webhooks::FluxEventsJob].each do |name|
    it "logs failure metadata and backtrace for #{name} without arguments or serialized copies" do
      job['wrapped'] = name
      context = { job: job, jobstr: job.to_json, context: secret }
      original = Marshal.load(Marshal.dump(context))
      described_class.call(exception, context, config)
      expect(output.string).to include(name, 'safe-jid', 'safe-job-id', 'critical', 'StandardError', 'example.rb:10')
      expect(output.string).not_to include(secret, '5511999999999', 'arguments')
      expect(context).to eq(original)
      expect(exception.message).to eq(secret)
    end
  end

  it 'does not dump an invalid serialized job whose class cannot be determined' do
    described_class.call(exception, { jobstr: secret, context: 'Invalid JSON for job' }, config)
    expect(output.string).to include('StandardError', 'example.rb:10')
    expect(output.string).not_to include(secret)
  end

  it 'preserves the default diagnostics for unrelated jobs' do
    job['wrapped'] = 'SendReplyJob'
    expect(Sidekiq::Config::ERROR_HANDLER).to receive(:call).with(exception, { job: job }, config)
    described_class.call(exception, { job: job }, config)
  end
end
