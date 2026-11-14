import { createStore } from 'vuex';
import conversations from '../index';
import ConversationApi from 'dashboard/api/inbox/conversation';
import MessageApi from 'dashboard/api/inbox/message';

vi.mock('dashboard/api/inbox/conversation', () => ({
  default: { get: vi.fn(), filter: vi.fn() },
}));
vi.mock('dashboard/api/inbox/message', () => ({
  default: { getPreviousMessages: vi.fn() },
}));

describe('conversation loading and request races', () => {
  let store;
  let state;
  beforeEach(() => {
    store = createStore({
      modules: {
        conversations: {
          ...conversations,
          state: structuredClone(conversations.state),
        },
      },
      mutations: {
        'contacts/SET_CONTACTS': vi.fn(),
        'conversationMetadata/SET_CONVERSATION_METADATA': vi.fn(),
      },
      actions: {
        'conversationStats/set': vi.fn(),
        'conversationLabels/setBulkConversationLabels': vi.fn(),
        'conversationPage/setCurrentPage': vi.fn(),
        'conversationPage/setEndReached': vi.fn(),
      },
    });
    state = store.state.conversations;
    state.listLoadingStatus = false;
    state.allConversations = [
      {
        id: 1,
        inbox_id: 2,
        messages: [{ id: 11, content: 'history A' }],
        meta: { sender: { id: 1 } },
      },
      {
        id: 2,
        inbox_id: 2,
        messages: [{ id: 22, content: 'history B' }],
        meta: { sender: { id: 2 } },
      },
    ];
    state.selectedChatId = 1;
    state.conversationFilters = { inboxId: 2, assigneeType: 'all', page: 1 };
  });

  it('preserves the list, selection and existing history during a refresh', async () => {
    let resolve;
    ConversationApi.get.mockReturnValue(
      new Promise(done => {
        resolve = done;
      })
    );
    const loading = store.dispatch('fetchAllConversations');
    expect(state.listLoadingStatus).toBe(true);
    expect(state.allConversations).toHaveLength(2);
    expect(state.selectedChatId).toBe(1);
    resolve({
      data: {
        data: {
          payload: [{ id: 1, messages: [], meta: { sender: { id: 1 } } }],
          meta: {},
        },
      },
    });
    expect(await loading).toBe(true);
    expect(state.allConversations[0].messages[0].content).toBe('history A');
    expect(state.listLoadingStatus).toBe(false);
  });

  it('ends loading on API failure, preserves data and recovers on retry', async () => {
    ConversationApi.get.mockRejectedValueOnce(new Error('offline'));
    expect(await store.dispatch('fetchAllConversations')).toBe(false);
    expect(state.listLoadingStatus).toBe(false);
    expect(state.listError).toBe(true);
    expect(state.selectedChatId).toBe(1);
    expect(state.allConversations).toHaveLength(2);
    ConversationApi.get.mockResolvedValue({
      data: { data: { payload: [], meta: {} } },
    });
    expect(await store.dispatch('fetchAllConversations')).toBe(true);
    expect(state.listError).toBe(false);
    expect(state.listLoadingStatus).toBe(false);
  });

  it('ignores an old inbox response after the scope changes', async () => {
    let resolveOld;
    ConversationApi.get.mockReturnValueOnce(
      new Promise(done => {
        resolveOld = done;
      })
    );
    const oldRequest = store.dispatch('fetchAllConversations');
    await store.dispatch('emptyAllConversations');
    state.conversationFilters = { inboxId: 3, assigneeType: 'all', page: 1 };
    ConversationApi.get.mockResolvedValueOnce({
      data: {
        data: {
          payload: [{ id: 3, inbox_id: 3, meta: { sender: {} } }],
          meta: {},
        },
      },
    });
    await store.dispatch('fetchAllConversations');
    resolveOld({
      data: { data: { payload: [{ id: 1, inbox_id: 2 }], meta: {} } },
    });
    expect(await oldRequest).toBe(false);
    expect(state.allConversations.map(item => item.id)).toEqual([3]);
  });

  it('does not let an old failure stop a newer request', async () => {
    let rejectOld;
    let resolveNew;
    ConversationApi.get.mockReturnValueOnce(
      new Promise((_, reject) => {
        rejectOld = reject;
      })
    );
    const oldRequest = store.dispatch('fetchAllConversations');
    ConversationApi.get.mockReturnValueOnce(
      new Promise(done => {
        resolveNew = done;
      })
    );
    const newRequest = store.dispatch('fetchAllConversations');
    rejectOld(new Error('old failure'));
    await oldRequest;
    expect(state.listLoadingStatus).toBe(true);
    expect(state.listError).toBe(false);
    resolveNew({ data: { data: { payload: [], meta: {} } } });
    await newRequest;
    expect(state.listLoadingStatus).toBe(false);
  });

  it('handles filtered list errors and recovery', async () => {
    ConversationApi.filter.mockRejectedValueOnce(new Error('offline'));
    expect(
      await store.dispatch('fetchFilteredConversations', {
        page: 1,
        queryData: {},
      })
    ).toBe(false);
    expect(state.listLoadingStatus).toBe(false);
    expect(state.listError).toBe(true);
    ConversationApi.filter.mockResolvedValueOnce({
      data: { payload: [], meta: {} },
    });
    expect(
      await store.dispatch('fetchFilteredConversations', {
        page: 1,
        queryData: {},
      })
    ).toBe(true);
    expect(state.listError).toBe(false);
  });

  it('keeps rapid A/B selections and delayed histories attached to their own conversation', async () => {
    let resolveA;
    let resolveB;
    MessageApi.getPreviousMessages.mockReturnValueOnce(
      new Promise(done => {
        resolveA = done;
      })
    );
    const requestA = store.dispatch('setActiveChat', {
      data: state.allConversations[0],
    });
    MessageApi.getPreviousMessages.mockReturnValueOnce(
      new Promise(done => {
        resolveB = done;
      })
    );
    const requestB = store.dispatch('setActiveChat', {
      data: state.allConversations[1],
    });
    expect(state.selectedChatId).toBe(2);
    expect(state.allConversations).toHaveLength(2);
    resolveB({ data: { payload: [{ id: 21, content: 'older B' }], meta: {} } });
    await requestB;
    resolveA({ data: { payload: [{ id: 10, content: 'older A' }], meta: {} } });
    await requestA;
    expect(state.selectedChatId).toBe(2);
    expect(state.allConversations[0].messages.map(item => item.id)).toEqual([
      10, 11,
    ]);
    expect(state.allConversations[1].messages.map(item => item.id)).toEqual([
      21, 22,
    ]);
  });

  it('does not mark failed histories as loaded and allows retry', async () => {
    const chat = state.allConversations[0];
    MessageApi.getPreviousMessages.mockRejectedValueOnce(new Error('offline'));
    await store.dispatch('setActiveChat', { data: chat });
    expect(chat.dataFetched).toBeUndefined();
    expect(chat.messageLoadError).toBe(true);
    expect(chat.isFetchingMessages).toBe(false);
    expect(chat.messages[0].content).toBe('history A');
    MessageApi.getPreviousMessages.mockResolvedValueOnce({
      data: { payload: [], meta: {} },
    });
    await store.dispatch('setActiveChat', { data: chat });
    expect(chat.dataFetched).toBe(true);
    expect(chat.messageLoadError).toBe(false);
  });

  it.each([
    ['anchor', 'B', 'A'],
    ['B', 'A', 'anchor'],
    ['A', 'anchor', 'B'],
  ])(
    'loads A -> B -> A with a message anchor in order %s / %s / %s',
    async (...order) => {
      const responses = {};
      state.allConversations[0].messages[0].created_at = 11;
      state.allConversations[1].messages[0].created_at = 22;
      MessageApi.getPreviousMessages.mockImplementation(
        ({ conversationId, after }) =>
          new Promise(resolve => {
            const name = conversationId === 1 ? 'A' : 'B';
            responses[after ? 'anchor' : name] = resolve;
          })
      );
      const firstA = store.dispatch('setActiveChat', {
        data: state.allConversations[0],
      });
      const requestB = store.dispatch('setActiveChat', {
        data: state.allConversations[1],
      });
      let anchorCompleted = false;
      const anchoredA = store
        .dispatch('setActiveChat', {
          data: state.allConversations[0],
          after: 5,
        })
        .then(() => {
          anchorCompleted = true;
        });
      expect(MessageApi.getPreviousMessages).toHaveBeenCalledTimes(3);
      expect(MessageApi.getPreviousMessages).toHaveBeenLastCalledWith({
        conversationId: 1,
        before: 11,
        after: 5,
      });
      await Promise.resolve();
      expect(anchorCompleted).toBe(false);
      const requests = { A: firstA, B: requestB, anchor: anchoredA };
      const payloads = {
        A: [{ id: 10, created_at: 10, content: 'older A' }],
        B: [{ id: 21, created_at: 21, content: 'older B' }],
        anchor: [
          { id: 5, created_at: 5, content: 'target A' },
          { id: 10, created_at: 10, content: 'overlapping A' },
        ],
      };
      await order.reduce(async (previous, name) => {
        await previous;
        responses[name]({ data: { payload: payloads[name], meta: {} } });
        await requests[name];
        expect(state.selectedChatId).toBe(1);
        if (name === 'anchor') {
          expect(
            state.allConversations[0].messages.some(message => message.id === 5)
          ).toBe(true);
        }
      }, Promise.resolve());
      expect(
        state.allConversations[0].messages.map(message => message.id)
      ).toEqual([5, 10, 11]);
      expect(
        state.allConversations[1].messages.map(message => message.id)
      ).toEqual([21, 22]);
      expect(state.allConversations[0].isFetchingMessages).toBe(false);
      expect(state.allConversations[1].isFetchingMessages).toBe(false);
      expect(state.allConversations[0].messageLoadError).toBe(false);
    }
  );

  it('shares identical pending ranges and keeps loading until both ranges settle', async () => {
    let resolveFirst;
    let resolveAnchor;
    MessageApi.getPreviousMessages.mockReturnValueOnce(
      new Promise(resolve => {
        resolveFirst = resolve;
      })
    );
    const data = { conversationId: 1, before: 11 };
    const first = store.dispatch('fetchPreviousMessages', data);
    const sameRange = store.dispatch('fetchPreviousMessages', { ...data });
    expect(MessageApi.getPreviousMessages).toHaveBeenCalledTimes(1);
    MessageApi.getPreviousMessages.mockReturnValueOnce(
      new Promise(resolve => {
        resolveAnchor = resolve;
      })
    );
    const anchor = store.dispatch('fetchPreviousMessages', {
      ...data,
      after: 5,
    });
    resolveAnchor({ data: { payload: [{ id: 5 }], meta: {} } });
    expect(await anchor).toBe(true);
    expect(state.allConversations[0].isFetchingMessages).toBe(true);
    resolveFirst({ data: { payload: [{ id: 10 }], meta: {} } });
    expect(await first).toBe(true);
    expect(await sameRange).toBe(true);
    expect(state.allConversations[0].isFetchingMessages).toBe(false);
  });

  it('does not reuse a pending range after the account or inbox context changes', async () => {
    let resolveOld;
    let resolveNew;
    MessageApi.getPreviousMessages.mockReturnValueOnce(
      new Promise(resolve => {
        resolveOld = resolve;
      })
    );
    const old = store.dispatch('fetchPreviousMessages', {
      conversationId: 1,
      before: 11,
      after: 5,
    });
    await store.dispatch('emptyAllConversations');
    state.allConversations = [{ id: 1, messages: [{ id: 99 }], meta: {} }];
    MessageApi.getPreviousMessages.mockReturnValueOnce(
      new Promise(resolve => {
        resolveNew = resolve;
      })
    );
    const current = store.dispatch('fetchPreviousMessages', {
      conversationId: 1,
      before: 11,
      after: 5,
    });
    expect(MessageApi.getPreviousMessages).toHaveBeenCalledTimes(2);
    resolveOld({
      data: { payload: [{ id: 5, content: 'old account' }], meta: {} },
    });
    expect(await old).toBe(false);
    expect(state.allConversations[0].isFetchingMessages).toBe(true);
    expect(state.allConversations[0].messages).toEqual([{ id: 99 }]);
    resolveNew({
      data: { payload: [{ id: 6, content: 'new account' }], meta: {} },
    });
    expect(await current).toBe(true);
    expect(
      state.allConversations[0].messages.map(message => message.id)
    ).toEqual([6, 99]);
    expect(state.allConversations[0].isFetchingMessages).toBe(false);
  });

  it('preserves history and retries a failed anchor while another range remains pending', async () => {
    let resolveFirst;
    MessageApi.getPreviousMessages.mockReturnValueOnce(
      new Promise(resolve => {
        resolveFirst = resolve;
      })
    );
    const first = store.dispatch('fetchPreviousMessages', {
      conversationId: 1,
      before: 11,
    });
    const anchor = { conversationId: 1, before: 11, after: 5 };
    MessageApi.getPreviousMessages.mockRejectedValueOnce(new Error('offline'));
    expect(await store.dispatch('fetchPreviousMessages', anchor)).toBe(false);
    expect(state.allConversations[0].isFetchingMessages).toBe(true);
    expect(state.allConversations[0].messageLoadError).toBe(true);
    expect(state.allConversations[0].messages[0].content).toBe('history A');
    MessageApi.getPreviousMessages.mockResolvedValueOnce({
      data: { payload: [{ id: 5 }], meta: {} },
    });
    expect(await store.dispatch('fetchPreviousMessages', anchor)).toBe(true);
    resolveFirst({ data: { payload: [], meta: {} } });
    await first;
    expect(state.allConversations[0].messageLoadError).toBe(false);
    expect(state.allConversations[0].isFetchingMessages).toBe(false);
    expect(
      state.allConversations[0].messages.map(message => message.id)
    ).toEqual([5, 11]);
  });

  it('loads a conversation with no cached messages', async () => {
    const chat = state.allConversations[0];
    chat.messages = [];
    MessageApi.getPreviousMessages.mockResolvedValueOnce({
      data: { payload: [], meta: {} },
    });
    await store.dispatch('setActiveChat', { data: chat });
    expect(chat.dataFetched).toBe(true);
    expect(MessageApi.getPreviousMessages).toHaveBeenCalledWith(
      expect.objectContaining({ before: undefined })
    );
  });

  it('does not merge delayed history into a new account or inbox context', async () => {
    let resolve;
    MessageApi.getPreviousMessages.mockReturnValueOnce(
      new Promise(done => {
        resolve = done;
      })
    );
    const request = store.dispatch('setActiveChat', {
      data: state.allConversations[0],
    });
    await store.dispatch('emptyAllConversations');
    state.allConversations = [
      { id: 1, messages: [{ id: 99, content: 'new context' }] },
    ];
    resolve({
      data: { payload: [{ id: 10, content: 'old context' }], meta: {} },
    });
    await request;
    expect(state.allConversations[0].messages).toEqual([
      { id: 99, content: 'new context' },
    ]);
    expect(state.allConversations[0].dataFetched).toBeUndefined();
  });
});
