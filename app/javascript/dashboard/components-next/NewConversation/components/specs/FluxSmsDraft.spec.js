import { shallowMount, flushPromises } from '@vue/test-utils';
import { createStore } from 'vuex';
import { reactive } from 'vue';
import ComposeConversation from '../../ComposeConversation.vue';

vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({ fetchSignatureFlagFromUISettings: () => false }),
}));
vi.mock(
  'dashboard/components-next/NewConversation/helpers/composeConversationHelper',
  () => ({
    createContactSearcher: () => vi.fn(),
    createNewContact: vi.fn(),
    fetchContactableInboxes: vi.fn().mockResolvedValue([]),
    processContactableInboxes: () => [],
    mergeInboxDetails: () => [],
  })
);

describe('New Flux conversation draft lifecycle', () => {
  let wrapper;
  let create;
  let form;
  let draft;
  beforeEach(async () => {
    const flags = reactive({ isCreating: false });
    create = vi.fn();
    const store = createStore({
      getters: {
        'contacts/getContactById': () => () => null,
        'contacts/getUIFlags': () => ({}),
        getCurrentUser: () => ({ id: 5 }),
        getCurrentAccountId: () => 2,
        'globalConfig/get': () => ({}),
        'contactConversations/getUIFlags': () => flags,
        getMessageSignature: () => '',
        'inboxes/getInboxes': () => [],
      },
      actions: {
        'contactConversations/create': async (_, payload) => {
          flags.isCreating = true;
          try {
            return await create(payload);
          } finally {
            flags.isCreating = false;
          }
        },
      },
    });
    wrapper = shallowMount(ComposeConversation, {
      global: {
        plugins: [store],
        stubs: {
          Popover: {
            template: '<div><slot name="content" /></div>',
            methods: { hide: vi.fn() },
          },
        },
      },
    });
    form = wrapper.findComponent({ name: 'ComposeNewConversationForm' });
    form.vm.$emit('updateTargetInbox', {
      id: 4,
      channelType: 'Channel::Sms',
      provider: 'flux',
    });
    form.vm.$emit('updateSelectedContact', { id: 3, name: 'Ana' });
    await flushPromises();
    draft = form.props('formState');
    draft.message = '{{contact.name}}';
  });
  afterEach(() => wrapper.unmount());

  it.each([422, 429, 500, 'network'])(
    'preserves Liquid and form content after %s',
    async status => {
      create.mockRejectedValue({
        response: status === 'network' ? undefined : { status },
      });
      form.vm.$emit('createConversation', {
        payload: { message: { content: draft.message } },
        isFromWhatsApp: false,
      });
      await flushPromises();
      expect(draft.message).toBe('{{contact.name}}');
      expect(form.props('selectedContact').id).toBe(3);
      expect(form.props('targetInbox').id).toBe(4);
      expect(form.props('smsPreviewRevision')).toBe(1);
    }
  );

  it('clears only after confirmed success', async () => {
    let resolve;
    create.mockReturnValue(
      new Promise(done => {
        resolve = done;
      })
    );
    form.vm.$emit('createConversation', {
      payload: { message: { content: draft.message } },
      isFromWhatsApp: false,
    });
    await wrapper.vm.$nextTick();
    expect(draft.message).toBe('{{contact.name}}');
    resolve({ account_id: 2, id: 9 });
    await flushPromises();
    expect(draft.message).toBe('');
  });

  it('preserves new text typed while an earlier Flux creation succeeds', async () => {
    let resolve;
    create.mockReturnValue(
      new Promise(done => {
        resolve = done;
      })
    );
    form.vm.$emit('createConversation', {
      payload: { message: { content: draft.message } },
      isFromWhatsApp: false,
    });
    await wrapper.vm.$nextTick();
    draft.message = 'Rascunho novo enquanto envia';
    resolve({ account_id: 2, id: 9 });
    await flushPromises();
    expect(draft.message).toBe('Rascunho novo enquanto envia');
  });

  it('does not create twice while the HTTP request is pending', async () => {
    let resolve;
    create.mockReturnValue(
      new Promise(done => {
        resolve = done;
      })
    );
    form.vm.$emit('createConversation', {
      payload: { message: { content: draft.message } },
      isFromWhatsApp: false,
    });
    form.vm.$emit('createConversation', {
      payload: { message: { content: draft.message } },
      isFromWhatsApp: false,
    });
    expect(create).toHaveBeenCalledTimes(1);
    resolve({ account_id: 2, id: 9 });
    await flushPromises();
  });

  it('does not clear a different target inbox when the earlier request succeeds', async () => {
    let resolve;
    create.mockReturnValue(
      new Promise(done => {
        resolve = done;
      })
    );
    form.vm.$emit('createConversation', {
      payload: { message: { content: draft.message } },
      isFromWhatsApp: false,
    });
    form.vm.$emit('updateTargetInbox', {
      id: 8,
      channelType: 'Channel::Sms',
      provider: 'flux',
    });
    resolve({ account_id: 2, id: 9 });
    await flushPromises();
    expect(draft.message).toBe('{{contact.name}}');
    expect(form.props('targetInbox').id).toBe(8);
  });
});
