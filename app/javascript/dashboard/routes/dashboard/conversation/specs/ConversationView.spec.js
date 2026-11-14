import ConversationView from '../ConversationView.vue';
import { emitter } from 'shared/helpers/mitt';
import { BUS_EVENTS } from 'shared/constants/busEvents';

vi.mock('shared/helpers/mitt', () => ({
  emitter: { emit: vi.fn(), on: vi.fn(), off: vi.fn() },
}));

describe('ConversationView anchored navigation completion', () => {
  it.each([
    ['anchor', 'B', 'A'],
    ['B', 'A', 'anchor'],
    ['A', 'anchor', 'B'],
  ])(
    'preserves the A -> B -> A anchor scroll in order %s / %s / %s',
    async (...order) => {
      const responses = [];
      const view = {
        conversationId: '1',
        currentChat: { id: 0 },
        $route: { query: {} },
        findConversation: vi.fn(() => ({ id: Number(view.conversationId) })),
        $store: {
          dispatch: vi.fn(
            () =>
              new Promise(resolve => {
                responses.push(resolve);
              })
          ),
        },
      };
      ConversationView.methods.setActiveChat.call(view);
      view.conversationId = '2';
      ConversationView.methods.setActiveChat.call(view);
      view.conversationId = '1';
      view.$route.query = { messageId: '5' };
      ConversationView.methods.setActiveChat.call(view);
      expect(view.$store.dispatch).toHaveBeenLastCalledWith('setActiveChat', {
        data: { id: 1 },
        after: '5',
      });
      const indices = { A: 0, B: 1, anchor: 2 };
      await order.reduce(async (previous, name) => {
        await previous;
        responses[indices[name]]();
        await Promise.resolve();
        if (name === 'anchor') {
          expect(emitter.emit).toHaveBeenCalledWith(
            BUS_EVENTS.SCROLL_TO_MESSAGE,
            { messageId: '5' }
          );
        }
      }, Promise.resolve());
      expect(emitter.emit).toHaveBeenCalledTimes(1);
    }
  );
});
