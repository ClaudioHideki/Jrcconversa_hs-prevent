class Api::V1::Accounts::Conversations::SmsPreviewsController < Api::V1::Accounts::BaseController
  def create
    channel = inbox.channel
    return head :unprocessable_entity unless channel.is_a?(Channel::Sms) && channel.flux?

    content = params[:content]
    return head :bad_request unless content.is_a?(String) && content.length <= 150_000

    render json: Sms::FluxMessagePreview.new(conversation: preview_conversation, sender: Current.user, content: content).perform
  end

  private

  def inbox
    @inbox ||= Current.account.inboxes.find(params[:inbox_id]).tap { |record| authorize record, :show? }
  end

  def contact
    @contact ||= Current.account.contacts.find(params[:contact_id]).tap { |record| authorize record, :show? }
  end

  def preview_conversation
    source_id = params.permit(:source_id)[:source_id].presence || contact.phone_number
    contact_inbox = contact.contact_inboxes.find_by(inbox: inbox, source_id: source_id)
    conversation = contact_inbox&.conversations&.last if inbox.lock_to_single_conversation?
    authorize conversation, :show? if conversation
    conversation || Current.account.conversations.build(inbox: inbox, contact: contact, assignee: Current.user)
  end
end
