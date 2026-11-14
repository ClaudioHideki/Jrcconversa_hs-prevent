import actions from '../actions';
import MessageApi from 'dashboard/api/inbox/message';
import types from '../../../mutation-types';

vi.mock('dashboard/api/inbox/message', () => ({
  default: { create: vi.fn() },
}));

describe('HTTP completion of message sending', () => {
  it('AUDIT: awaits the HTTP action before reporting success', async () => {
    let resolve;
    const dispatch = vi.fn(
      () =>
        new Promise(done => {
          resolve = done;
        })
    );
    let completed = false;
    const submission = actions.createPendingMessageAndSend(
      { dispatch },
      { message: 'texto', conversationId: 1 }
    );
    submission.then(() => {
      completed = true;
    });
    await Promise.resolve();
    expect(completed).toBe(false);
    resolve();
    await submission;
    expect(completed).toBe(true);
  });

  it.each([422, 429, 500, 'network'])(
    'propagates %s without retrying',
    async status => {
      const commit = vi.fn();
      const error =
        status === 'network'
          ? new Error('offline')
          : { response: { status, data: { error: 'rejected' } } };
      MessageApi.create.mockRejectedValueOnce(error);
      const dispatch = (_, pending) =>
        actions.sendMessageWithData({ commit }, pending);
      await expect(
        actions.createPendingMessageAndSend(
          { dispatch },
          { message: '{{contact.name}}', conversationId: 1 }
        )
      ).rejects.toBe(error);
      expect(MessageApi.create).toHaveBeenCalledTimes(1);
      expect(commit).toHaveBeenCalledWith(
        types.ADD_MESSAGE,
        expect.objectContaining({
          status: 'failed',
          content: '{{contact.name}}',
        })
      );
    }
  );

  it('marks success only after the HTTP request resolves', async () => {
    let resolve;
    const commit = vi.fn();
    MessageApi.create.mockReturnValueOnce(
      new Promise(done => {
        resolve = done;
      })
    );
    const dispatch = (_, pending) =>
      actions.sendMessageWithData({ commit }, pending);
    const request = actions.createPendingMessageAndSend(
      { dispatch },
      { message: 'ok', conversationId: 1 }
    );
    expect(commit).not.toHaveBeenCalledWith(
      types.ADD_MESSAGE,
      expect.objectContaining({ status: 'sent' })
    );
    resolve({ data: { id: 123, content: 'ok', conversation_id: 1 } });
    await request;
    expect(commit).toHaveBeenCalledWith(
      types.ADD_MESSAGE,
      expect.objectContaining({ id: 123, status: 'sent' })
    );
  });
});
