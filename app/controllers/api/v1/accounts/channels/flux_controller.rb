class Api::V1::Accounts::Channels::FluxController < Api::V1::Accounts::BaseController
  def test_connection
    authorize Current.account, :update?
    config = params.permit(:inbox_id, :flux_account, :flux_code)
    channel = if config[:inbox_id].present?
                Current.account.inboxes.find(config[:inbox_id]).channel
              else
                Current.account.sms_channels.new(provider: 'flux')
              end
    return head :unprocessable_entity unless channel.is_a?(Channel::Sms) && channel.flux?

    channel.assign_attributes(config.slice(:flux_account, :flux_code))
    return render json: { error: channel.errors.full_messages.join(', ') }, status: :unprocessable_entity unless channel.valid?

    Sms::Providers::FluxService.new(channel).test_connection
    render json: { success: true }
  rescue Sms::Providers::FluxService::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
