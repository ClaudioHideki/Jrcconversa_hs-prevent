# == Schema Information
#
# Table name: channel_sms
#
#  id              :bigint           not null, primary key
#  phone_number    :string           not null
#  provider        :string           default("default")
#  provider_config :jsonb
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :integer          not null
#
# Indexes
#
#  index_channel_sms_on_phone_number  (phone_number) UNIQUE
#

class Channel::Sms < ApplicationRecord
  include Channelable

  self.table_name = 'channel_sms'
  EDITABLE_ATTRS = [:phone_number, :provider, :flux_account, :flux_code, { provider_config: {} }].freeze
  attr_accessor :flux_account, :flux_code

  validates :phone_number, presence: true, uniqueness: true, unless: :flux?
  validates :provider, inclusion: { in: %w[default bandwidth flux] }, on: :create
  before_validation :configure_flux, if: :flux?
  validate :validate_flux, if: :flux?
  validate :prevent_provider_change, on: :update
  # before_save :validate_provider_config

  def name
    'Sms'
  end

  # all this should happen in provider service . but hack mode on
  def api_base_path
    'https://messaging.bandwidth.com/api/v2'
  end

  def send_message(contact_number, message)
    return Sms::Providers::FluxService.new(self).send_message(contact_number, message) if flux?

    body = message_body(contact_number, message.outgoing_content)
    body['media'] = message.attachments.map(&:download_url) if message.attachments.present?

    send_to_bandwidth(body, message)
  end

  def send_text_message(contact_number, message_content)
    return Sms::Providers::FluxService.new(self).send_text(contact_number, message_content) if flux?

    body = message_body(contact_number, message_content)
    send_to_bandwidth(body)
  end

  def flux?
    provider == 'flux'
  end

  def flux_secrets
    return {} if flux_credentials.blank?

    Sms::FluxCredentials.decrypt(flux_credentials)
  end

  def flux_callback_url
    "#{ENV.fetch('FRONTEND_URL').delete_suffix('/')}/f?t=#{flux_secrets.fetch('callback_token')}"
  end

  def flux_public_config
    secrets = flux_secrets
    provider_config.slice('send_type', 'client').merge(
      'account_masked' => secrets.fetch('account', '').gsub(/.(?=.{3})/, '*'),
      'configured' => secrets['code'].present?
    )
  end

  private

  def configure_flux
    self.phone_number = nil
    secrets = flux_secrets
    secrets['account'] = flux_account.strip if flux_account.present?
    secrets['code'] = flux_code if flux_code.present?
    secrets['callback_token'] ||= SecureRandom.urlsafe_base64(12)
    self.flux_credentials = Sms::FluxCredentials.encrypt(secrets)
    self.flux_callback_digest = Digest::SHA256.hexdigest(secrets.fetch('callback_token'))
    self.provider_config = (provider_config || {}).slice('send_type', 'client').reverse_merge('send_type' => '1')
  end

  def validate_flux
    secrets = flux_secrets
    errors.add(:flux_account, :blank) if secrets['account'].blank?
    errors.add(:flux_code, :blank) if secrets['code'].blank?
    errors.add(:flux_account, :invalid) if secrets['account'].to_s.match?(/[\r\n]/) || secrets['account'].to_s.length > 100
    errors.add(:flux_code, :invalid) if secrets['code'].to_s.match?(/[\r\n]/)
    errors.add(:provider_config, :invalid) unless %w[1 2 4 7].include?(provider_config['send_type'].to_s)
    errors.add(:provider_config, :too_long, count: 200) if provider_config['client'].to_s.length > 200
  end

  def prevent_provider_change
    errors.add(:provider, :invalid) if provider_changed?
  end

  def message_body(contact_number, message_content)
    {
      'to' => contact_number,
      'from' => phone_number,
      'text' => message_content,
      'applicationId' => provider_config['application_id']
    }
  end

  def send_to_bandwidth(body, message = nil)
    response = HTTParty.post(
      "#{api_base_path}/users/#{provider_config['account_id']}/messages",
      basic_auth: bandwidth_auth,
      headers: { 'Content-Type' => 'application/json' },
      body: body.to_json
    )

    if response.success?
      response.parsed_response['id']
    else
      handle_error(response, message)
      nil
    end
  end

  def handle_error(response, message)
    Rails.logger.error("[#{account_id}] Error sending SMS: #{response.parsed_response['description']}")
    return if message.blank?

    # https://dev.bandwidth.com/apis/messaging-apis/messaging/#tag/Messages/operation/createMessage
    message.external_error = response.parsed_response['description']
    message.status = :failed
    message.save!
  end

  def bandwidth_auth
    { username: provider_config['api_key'], password: provider_config['api_secret'] }
  end

  # Extract later into provider Service
  # let's revisit later
  def validate_provider_config
    response = HTTParty.post(
      "#{api_base_path}/users/#{provider_config['account_id']}/messages",
      basic_auth: bandwidth_auth,
      headers: { 'Content-Type': 'application/json' }
    )
    errors.add(:provider_config, 'error setting up') unless response.success?
  end
end
