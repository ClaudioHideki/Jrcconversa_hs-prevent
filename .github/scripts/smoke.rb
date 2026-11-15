require 'json'
require 'digest'

raise 'Smoke must use the isolated test database' unless ENV.fetch('POSTGRES_DATABASE') == 'jrc_release_test'
Rails.application.eager_load!
Rails.logger.level = Logger::ERROR
ActiveJob::Base.queue_adapter = :test
HTTParty.define_singleton_method(:post) { |*| raise 'External HTTP is forbidden in this smoke test' }
HTTParty.define_singleton_method(:get) { |*| raise 'External HTTP is forbidden in this smoke test' }

manifest = JSON.parse(File.read('/app/public/vite/.vite/manifest.json'))
assets = manifest.values.flat_map { |entry| [entry['file'], *entry['css'], *entry['assets']] }.compact.uniq
missing = assets.reject { |asset| File.file?(File.join('/app/public/vite', asset)) }
raise "Missing assets: #{missing.join(', ')}" if missing.any?
raise 'SDK missing' unless File.size?('/app/public/packs/js/sdk.js')
raise 'Parallel frontend SMS renderer remains' if File.exist?('/app/app/javascript/dashboard/helper/fluxSmsHelper.js')

ActiveRecord::Base.transaction do
  account = Account.create!(name: 'Isolated official image smoke')
  user = User.create!(name: 'Local agent', email: "smoke-#{SecureRandom.hex(8)}@example.invalid",
                      password: 'Local-smoke-password-2026!', confirmed_at: Time.current)
  AccountUser.create!(account: account, user: user, role: :agent)
  channel = account.sms_channels.create!(provider: 'flux', flux_account: 'smoke@example.invalid', flux_code: 'dummy-local-only',
                                         provider_config: { 'send_type' => '2' })
  inbox = account.inboxes.create!(name: 'Local Flux smoke', channel: channel)
  InboxMember.create!(inbox: inbox, user: user)
  contact = account.contacts.create!(name: 'a' * 161, phone_number: '+5511999999999')
  contact_inbox = ContactInbox.create!(contact: contact, inbox: inbox, source_id: '5511999999999')
  conversation = account.conversations.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox).reload
  headers = user.create_new_auth_token
  session = ActionDispatch::Integration::Session.new(Rails.application)
  session.host! 'localhost'
  session.https!
  url = "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages/sms_preview"
  messages_before = Message.count
  jobs_before = ActiveJob::Base.queue_adapter.enqueued_jobs.length

  session.post(url, params: { content: "#{'a' * 131} [JRC](https://exemplo.com/ação)" }, headers: headers, as: :json)
  raise "Unicode preflight HTTP #{session.response.status}" unless session.response.status == 200
  data = JSON.parse(session.response.body)
  raise 'Unicode URL count differs' unless data.values_at('length', 'limit', 'excess', 'valid') == [160, 160, 0, true]

  session.post(url, params: { content: '{{contact.name}}' }, headers: headers, as: :json)
  raise 'Liquid preflight failed' unless session.response.status == 200
  data = JSON.parse(session.response.body)
  raise 'Liquid count differs' unless data.values_at('length', 'limit', 'excess', 'valid') == [161, 160, 1, false]
  raise 'Preview leaks content or credentials' unless data.keys.sort == %w[empty excess length limit valid]

  session.post(url.delete_suffix('/sms_preview'), params: { content: '{{contact.name}}', message_type: 'outgoing' },
               headers: headers, as: :json)
  raise "Expanded over-limit send was not rejected: #{session.response.status}" unless session.response.status == 422

  channel.update!(provider_config: { 'send_type' => '4' })
  session.post(url, params: { content: 'a' * 1280 }, headers: headers, as: :json)
  data = JSON.parse(session.response.body)
  raise 'Carta changed' unless data.values_at('length', 'limit', 'valid') == [1280, 1280, true]
  raise 'Preview persisted messages' unless Message.count == messages_before
  raise 'Preview enqueued jobs' unless ActiveJob::Base.queue_adapter.enqueued_jobs.length == jobs_before

  channel.update!(provider_config: { 'send_type' => '2' })
  message = conversation.messages.create!(account: account, inbox: inbox, sender: user, message_type: :outgoing,
                                          content: 'Synthetic runtime DLR', source_id: 'runtime-provider-id',
                                          content_attributes: { flux_phone: '5511999999999' })
  message.update!(content_attributes: message.content_attributes.merge('flux_partner_id' => "JRC-SMS-#{message.id}"))
  event = { telefone: '5511999999999', id: message.source_id, idParceiro: "JRC-SMS-#{message.id}",
            status: 'SPAM', data: '2026-11-15 12:00:00' }
  job = Webhooks::FluxEventsJob.new(channel.id, [event])
  ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper.new.perform(job.serialize)
  raise 'Flux rejection missing' unless message.reload.failed? && message.external_error == 'Flux: SPAM'
  event.merge!(status: 'ENTREGUE', data: '2026-11-15 13:00:00')
  Webhooks::FluxEventsJob.perform_now(channel.id, [event])
  raise 'Real status event was not reflected' unless message.reload.delivered? && message.external_error.nil?
  saved_at = message.updated_at
  Webhooks::FluxEventsJob.perform_now(channel.id, [event])
  Webhooks::FluxEventsJob.perform_now(channel.id, [event.merge(status: 'SPAM', data: '2026-11-15 12:30:00')])
  raise 'Duplicate or delayed event regressed delivery' unless message.reload.delivered? && message.updated_at == saved_at

  twilio = Channel::TwilioSms.create!(account: account, account_sid: 'ACsynthetic', auth_token: 'LOCAL-ONLY',
                                     messaging_service_sid: 'MGsynthetic', provider_config: {})
  twilio_inbox = account.inboxes.create!(name: 'Synthetic Twilio', channel: twilio)
  ci = ContactInbox.create!(contact: contact, inbox: twilio_inbox, source_id: contact.phone_number)
  tc = account.conversations.create!(inbox: twilio_inbox, contact: contact, contact_inbox: ci)
  tm = tc.messages.create!(account: account, inbox: twilio_inbox, sender: user, message_type: :outgoing,
                           content: 'Synthetic Twilio rejection', source_id: 'SMsynthetic', content_attributes: { marker: 'preserved' })
  Twilio::DeliveryStatusService.new(params: { MessagingServiceSid: twilio.messaging_service_sid, MessageSid: tm.source_id,
                                            MessageStatus: 'undelivered', ErrorCode: '30008', ErrorMessage: 'Unknown error' }).perform
  raise 'Twilio metadata lost' unless tm.reload.external_error == '30008 - Unknown error' && tm.content_attributes['marker'] == 'preserved'
  raise 'Job argument privacy changed' unless !ActionCableBroadcastJob.log_arguments? && !EventDispatcherJob.log_arguments?
  require 'stringio'
  output = StringIO.new
  config = Sidekiq::Config.new
  config.logger = Logger.new(output)
  SensitiveJobErrorLogger.call(StandardError.new('PRIVATE-RUNTIME-SENTINEL'),
                              { job: { 'wrapped' => 'EventDispatcherJob', 'jid' => 'safe-jid', 'queue' => 'critical',
                                       'args' => [{ 'job_id' => 'safe-job-id', 'arguments' => ['PRIVATE-RUNTIME-SENTINEL'] }] } }, config)
  raise 'Sidekiq exposed arguments' if output.string.include?('PRIVATE-RUNTIME-SENTINEL')
  raise 'Sidekiq diagnostics missing' unless output.string.include?('safe-job-id')
  puts 'PASS: serialized Flux rejection/delivery, duplicates, delayed status, Twilio metadata and private job logs.'
  puts 'PASS: production Rails eager load; authenticated Unicode/Liquid/Carta preflight preserves messages/jobs; expanded send rejected; external HTTP blocked.'
  raise ActiveRecord::Rollback
end

puts "PASS: #{assets.length} referenced Vite assets; SDK built and present; no frontend parallel renderer."
puts "SDK_SHA256=#{Digest::SHA256.file('/app/public/packs/js/sdk.js').hexdigest}"
puts "SOURCE_REVISION=#{File.read('/app/.git_sha').strip}"
raise 'Smoke left synthetic messages' unless Message.count.zero? && Account.count.zero?
