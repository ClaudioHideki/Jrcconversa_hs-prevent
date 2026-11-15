import { reactive } from 'vue';
import { mutations } from '../../conversations';
import actions from '../../conversations/actions';
import types from '../../../mutation-types';

describe('Flux realtime message updates', () => {
  const message = (status, attributes = {}) => ({
    id: 40,
    account_id: 1,
    conversation_id: 2,
    message_type: 1,
    content: 'Preserved SMS',
    created_at: 1794744000,
    source_id: '1234567',
    status,
    content_attributes: { flux_partner_id: 'JRC-SMS-40', ...attributes },
  });

  it('updates the existing bubble without fetching or refreshing the conversation', () => {
    const state = reactive({
      selectedChatId: 2,
      allConversations: [{ id: 2, messages: [message('sent')] }],
    });
    const commit = (type, payload) => mutations[type](state, payload);
    actions.updateMessage(
      { commit },
      message('delivered', {
        flux_status: 'ENTREGUE',
        flux_status_at: '2026-11-15T12:00:00Z',
      })
    );
    expect(state.allConversations[0].messages).toHaveLength(1);
    expect(state.allConversations[0].messages[0].status).toBe('delivered');
    expect(state.allConversations[0].messages[0].content).toBe('Preserved SMS');
    expect(state.selectedChatId).toBe(2);
  });

  it.each(['delivered', 'failed'])(
    'does not replace a Flux %s callback with a delayed HTTP sent response',
    status => {
      const previous = message(status, {
        flux_status: status === 'delivered' ? 'ENTREGUE' : 'SPAM',
        flux_status_at: '2026-11-15T12:00:00Z',
        external_error: status === 'failed' ? 'Flux: SPAM' : null,
      });
      const state = {
        selectedChatId: 2,
        allConversations: [{ id: 2, messages: [previous] }],
      };
      mutations[types.ADD_MESSAGE](state, message('sent'));
      expect(state.allConversations[0].messages[0].status).toBe(status);
      expect(
        state.allConversations[0].messages[0].content_attributes
      ).toMatchObject(previous.content_attributes);
    }
  );

  it('keeps a synchronous Flux API rejection if the HTTP response arrives later', () => {
    const previous = message('failed', {
      external_error: 'Flux 175: Mensagem classificada como spam',
    });
    const state = {
      selectedChatId: 2,
      allConversations: [{ id: 2, messages: [previous] }],
    };
    mutations[types.ADD_MESSAGE](state, message('sent'));
    expect(state.allConversations[0].messages[0].status).toBe('failed');
    expect(
      state.allConversations[0].messages[0].content_attributes.external_error
    ).toBe(previous.content_attributes.external_error);
  });

  it('does not replace confirmed delivery with an older failed broadcast job', () => {
    const previous = message('delivered', {
      flux_status: 'ENTREGUE',
      flux_status_at: '2026-11-15T13:00:00Z',
    });
    const state = {
      selectedChatId: 2,
      allConversations: [{ id: 2, messages: [previous] }],
    };
    mutations[types.ADD_MESSAGE](
      state,
      message('failed', {
        flux_status: 'SPAM',
        flux_status_at: '2026-11-15T12:00:00Z',
        external_error: 'Flux: SPAM',
      })
    );
    expect(state.allConversations[0].messages[0].status).toBe('delivered');
    expect(state.allConversations[0].messages[0].content_attributes).toEqual({
      ...previous.content_attributes,
      external_error: null,
    });
  });

  it('keeps the accepted source id when an older HTTP response or broadcast has no provider id', () => {
    const previous = message('sent');
    const state = {
      selectedChatId: 2,
      allConversations: [{ id: 2, messages: [previous] }],
    };
    mutations[types.ADD_MESSAGE](state, {
      ...message('sent'),
      source_id: null,
      content_attributes: {},
    });
    expect(state.allConversations[0].messages[0].source_id).toBe('1234567');
    expect(
      state.allConversations[0].messages[0].content_attributes.flux_partner_id
    ).toBe('JRC-SMS-40');
  });
});
