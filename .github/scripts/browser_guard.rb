raise 'Isolated GitHub runner required' unless ENV['GITHUB_ACTIONS'] == 'true' && ENV['POSTGRES_DATABASE'] == 'jrc_browser_test'

Rails.application.config.after_initialize do
  adapter = ActiveJob::QueueAdapters::TestAdapter.new
  adapter.perform_enqueued_jobs = true
  adapter.filter = [Webhooks::FluxEventsJob, ActionCableBroadcastJob]
  ActiveJob::Base.queue_adapter = adapter
  HTTParty.define_singleton_method(:get) { |*| raise 'External HTTP blocked in isolated browser tests' }
  HTTParty.define_singleton_method(:post) { |*| raise 'External HTTP blocked in isolated browser tests' }
end
