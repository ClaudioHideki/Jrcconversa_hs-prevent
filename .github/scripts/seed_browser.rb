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
rejections = ['BLOQUEADA', 'NAO ENTREGUE'].map do |status|
  record = conversation.messages.create!(account: account, inbox: inbox, sender: user,
                                         content: "SMS ficticio para #{status}", message_type: :outgoing)
  record.update!(source_id: "JRC-SMS-#{record.id}",
                 content_attributes: { flux_partner_id: "JRC-SMS-#{record.id}", flux_phone: '5511999999999' })
  { id: record.id, source_id: record.source_id, status: status }
end
other_account = Account.create!(name: 'Other isolated account', locale: 'pt_BR')
other_channel = other_account.sms_channels.create!(provider: 'flux', flux_account: 'other@example.invalid', flux_code: 'LOCAL-NO-SEND')
other_inbox = other_account.inboxes.create!(name: 'Other isolated SMS inbox', channel: other_channel)
other_contact = other_account.contacts.create!(name: 'Other synthetic contact', phone_number: '+5511999999999')
other_contact_inbox = ContactInbox.create!(contact: other_contact, inbox: other_inbox, source_id: other_contact.phone_number)
other_conversation = other_account.conversations.create!(inbox: other_inbox, contact: other_contact, contact_inbox: other_contact_inbox)
other_message = other_conversation.messages.create!(account: other_account, inbox: other_inbox, content: 'Other isolated SMS', message_type: :outgoing)
other_message.update!(source_id: "JRC-SMS-#{other_message.id}",
                      content_attributes: { flux_partner_id: "JRC-SMS-#{other_message.id}", flux_phone: '5511999999999' })
File.write('tmp/ci-evidence/browser-fixtures.json', JSON.pretty_generate(
  account_id: account.id, inbox_id: inbox.id, conversations: conversations, delivery_id: message.id,
  callback_token: channel.flux_secrets.fetch('callback_token'), source_id: message.source_id, rejections: rejections,
  other: { account_id: other_account.id, display_id: other_conversation.display_id, source_id: other_message.source_id,
           callback_token: other_channel.flux_secrets.fetch('callback_token') }
))
puts 'PASS: synthetic browser fixtures; no worker or outbound SMS'
