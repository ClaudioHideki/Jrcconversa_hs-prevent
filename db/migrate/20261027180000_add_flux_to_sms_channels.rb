class AddFluxToSmsChannels < ActiveRecord::Migration[7.1]
  def change
    change_column_null :channel_sms, :phone_number, true
    add_column :channel_sms, :flux_credentials, :text
    add_column :channel_sms, :flux_callback_digest, :string
    add_index :channel_sms, :flux_callback_digest, unique: true
  end
end
