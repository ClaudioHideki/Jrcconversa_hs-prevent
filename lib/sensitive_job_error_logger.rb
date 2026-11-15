# Keep Sidekiq's operational failure logs without undoing ActiveJob's per-job
# log_arguments policy. Never change the job/exception used for retries or delivery.
class SensitiveJobErrorLogger
  def self.call(exception, context, config)
    job = context[:job] || {}
    return Sidekiq::Config::ERROR_HANDLER.call(exception, context, config) unless protected_job?(job) || context.key?(:jobstr)

    payload = Array(job['args']).first
    metadata = job.slice('class', 'wrapped', 'jid', 'queue', 'retry_count')
    metadata['job_id'] = payload['job_id'] if payload.is_a?(Hash)
    config.logger.warn(Sidekiq.dump_json(context: 'Job failure; argument details omitted', job: metadata, error_class: exception.class.name))
    config.logger.warn(config[:backtrace_cleaner].call(exception.backtrace).join("\n")) if exception.backtrace
  end

  def self.protected_job?(job)
    job_class = job['wrapped']&.safe_constantize
    job_class.respond_to?(:log_arguments?) && !job_class.log_arguments?
  end
  private_class_method :protected_job?
end
