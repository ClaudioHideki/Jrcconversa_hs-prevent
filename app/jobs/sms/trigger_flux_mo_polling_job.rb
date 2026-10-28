class Sms::TriggerFluxMoPollingJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    Channel::Sms.where(provider: 'flux').joins(:inbox)
                .where("provider_config ->> 'mo_polling_enabled' = ?", 'true').find_each do |channel|
      Sms::FetchFluxMoJob.perform_later(channel.id)
    end
  end
end
