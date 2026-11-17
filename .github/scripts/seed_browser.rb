require 'json'
raise 'Isolated browser database required' unless ENV['GITHUB_ACTIONS'] == 'true' && ENV['POSTGRES_DATABASE'] == 'jrc_browser_test'
raise 'Browser database must be empty' unless Account.count.zero? && User.count.zero? && Message.count.zero?
GlobalConfig.clear_cache
ConfigLoader.new.process
account = Account.create!(name: 'Flux isolated browser validation', locale: 'pt_BR')
user = User.create!(name: 'Isolated Agent', email: 'browser@example.invalid', password: 'Isolated-browser-only-2026!', confirmed_at: Time.current)
AccountUser.create!(account: account, user: user, role: :administrator)
channel = account.sms_channels.create!(provider: 'flux', flux_account: 'browser@example.invalid', flux_code: 'LOCAL-NO-SEND',
                                       provider_config: { 'send_type' => '2', 'mo_polling_enabled' => false })
inbox = account.inboxes.create!(name: 'SMS_2 Teste Isolado', channel: channel)
InboxMember.create!(inbox: inbox, user: user)
conversations = [['a' * 161, '+5511999999999', 'Histórico fictício A'], ['Contato B', '+5511888888888', 'Histórico fictício B']].map do |name, phone, text|
  contact = account.contacts.create!(name: name, phone_number: phone)
  contact_inbox = ContactInbox.create!(contact: contact, inbox: inbox, source_id: phone)
  conversation = account.conversations.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox, assignee: user, status: :open).reload
  conversation.messages.create!(account: account, inbox: inbox, sender: contact, content: text, message_type: :incoming)
  { id: conversation.id, display_id: conversation.display_id, contact_id: contact.id, name: name, history: text }
end
conversation = account.conversations.find(conversations.first[:id])
message = conversation.messages.create!(account: account, inbox: inbox, sender: user, content: 'SMS fictício aceito', message_type: :outgoing)
message.update!(source_id: "JRC-SMS-#{message.id}",
                content_attributes: { flux_partner_id: "JRC-SMS-#{message.id}", flux_phone: '5511999999999' })
File.write('tmp/ci-evidence/browser-fixtures.json', JSON.pretty_generate(
  account_id: account.id, inbox_id: inbox.id, conversations: conversations, delivery_id: message.id,
  callback_token: channel.flux_secrets.fetch('callback_token'), source_id: message.source_id
))
puts 'PASS: synthetic browser fixtures; no worker or outbound SMS'
