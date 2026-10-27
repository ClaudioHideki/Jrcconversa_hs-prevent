class Sms::FluxCredentials
  def self.encrypt(value)
    encryptor.encrypt_and_sign(value)
  end

  def self.decrypt(value)
    encryptor.decrypt_and_verify(value)
  end

  def self.encryptor
    key = Rails.application.key_generator.generate_key('sms/flux/credentials/v1', 32)
    ActiveSupport::MessageEncryptor.new(key, cipher: 'aes-256-gcm', serializer: JSON)
  end
  private_class_method :encryptor
end
