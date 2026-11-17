import { shallowMount, flushPromises, config } from '@vue/test-utils';
import { reactive, ref } from 'vue';
import MessageApi from 'dashboard/api/inbox/message';
import Form from '../ComposeNewConversationForm.vue';
import FluxSmsCounter from 'dashboard/components/widgets/conversation/FluxSmsCounter.vue';

vi.mock('dashboard/api/inbox/message', () => ({
  default: { previewNewSms: vi.fn() },
}));
vi.mock('dashboard/composables/useCopilotReply', () => ({
  useCopilotReply: () => ({ isActive: ref(false), reset: vi.fn() }),
}));
vi.mock('dashboard/composables/useKeyboardEvents', () => ({
  useKeyboardEvents: vi.fn(),
}));

describe('New conversation Flux SMS guard', () => {
  let wrapper;
  let state;
  let flags;
  beforeEach(() => {
    vi.useFakeTimers();
    config.global.plugins[0].global.locale.value = 'pt_BR';
    state = reactive({
      message: '',
      subject: '',
      ccEmails: '',
      bccEmails: '',
      attachedFiles: [],
    });
    flags = reactive({ isCreating: false });
    wrapper = shallowMount(Form, {
      props: {
        accountId: 2,
        selectedContact: { id: 3, name: 'Ana', contactInboxes: [] },
        targetInbox: {
          id: 4,
          channelType: 'Channel::Sms',
          provider: 'flux',
          smsCharacterLimit: 160,
        },
        currentUser: { id: 5, name: 'Agent' },
        contactConversationsUiFlags: flags,
        contactsUiFlags: {},
        formState: state,
        onCreateConversation: () => {
          flags.isCreating = true;
        },
      },
      global: { stubs: { FluxSmsCounter: false } },
    });
  });
  afterEach(() => {
    wrapper.unmount();
    vi.clearAllTimers();
    vi.useRealTimers();
    config.global.plugins[0].global.locale.value = 'en';
  });

  it.each([159, 160, 161])(
    'guards the %i boundary without changing the draft',
    async length => {
      MessageApi.previewNewSms.mockResolvedValue({
        data: {
          length,
          limit: 160,
          excess: Math.max(length - 160, 0),
          empty: false,
          valid: length <= 160,
        },
      });
      state.message = '😀'.repeat(length);
      await vi.advanceTimersByTimeAsync(200);
      const buttons = wrapper.findComponent({ name: 'ActionButtons' });
      expect(buttons.props('disableSendButton')).toBe(length > 160);
      expect(wrapper.get('[data-testid="flux-sms-counter"]').text()).toContain(
        `${length} / 160`
      );
      buttons.vm.$emit('sendMessage');
      await flushPromises();
      expect(wrapper.emitted('createConversation')?.length || 0).toBe(
        length <= 160 ? 1 : 0
      );
      expect(state.message).toBe('😀'.repeat(length));
    }
  );

  it('blocks direct send events while checking and after preview failure; retry preserves Liquid', async () => {
    MessageApi.previewNewSms.mockRejectedValueOnce(new Error('offline'));
    state.message = '{{contact.name}}';
    await wrapper.vm.$nextTick();
    const buttons = wrapper.findComponent({ name: 'ActionButtons' });
    buttons.vm.$emit('sendMessage');
    await flushPromises();
    expect(wrapper.emitted('createConversation')).toBeUndefined();
    await vi.advanceTimersByTimeAsync(200);
    buttons.vm.$emit('sendMessage');
    await flushPromises();
    expect(wrapper.emitted('createConversation')).toBeUndefined();
    expect(state.message).toBe('{{contact.name}}');
    MessageApi.previewNewSms.mockResolvedValueOnce({
      data: { length: 3, limit: 160, excess: 0, empty: false, valid: true },
    });
    await wrapper.getComponent(FluxSmsCounter).find('button').trigger('click');
    await vi.advanceTimersByTimeAsync(0);
    expect(buttons.props('disableSendButton')).toBe(false);
  });

  it('rejects a previously valid count immediately when the contact context changes', async () => {
    MessageApi.previewNewSms.mockResolvedValue({
      data: { length: 3, limit: 160, excess: 0, empty: false, valid: true },
    });
    state.message = '{{contact.name}}';
    await vi.advanceTimersByTimeAsync(200);
    await wrapper.setProps({
      selectedContact: { id: 9, name: 'Long name', contactInboxes: [] },
    });
    wrapper.findComponent({ name: 'ActionButtons' }).vm.$emit('sendMessage');
    await flushPromises();
    expect(wrapper.emitted('createConversation')).toBeUndefined();
    expect(state.message).toBe('{{contact.name}}');
  });

  it('blocks duplicate send events while creation is pending', async () => {
    MessageApi.previewNewSms.mockResolvedValue({
      data: { length: 3, limit: 160, excess: 0, empty: false, valid: true },
    });
    state.message = 'SMS';
    await vi.advanceTimersByTimeAsync(200);
    const buttons = wrapper.findComponent({ name: 'ActionButtons' });
    buttons.vm.$emit('sendMessage');
    buttons.vm.$emit('sendMessage');
    await flushPromises();
    expect(wrapper.emitted('createConversation')).toHaveLength(1);
    expect(state.message).toBe('SMS');
  });

  it('preserves Carta 1280 and hides the Flux guard for other channels', async () => {
    await wrapper.setProps({
      targetInbox: {
        id: 4,
        channelType: 'Channel::Sms',
        provider: 'flux',
        smsCharacterLimit: 1280,
      },
    });
    MessageApi.previewNewSms.mockResolvedValue({
      data: { length: 1280, limit: 1280, excess: 0, empty: false, valid: true },
    });
    state.message = 'a'.repeat(1280);
    await vi.advanceTimersByTimeAsync(200);
    expect(
      wrapper
        .findComponent({ name: 'ActionButtons' })
        .props('disableSendButton')
    ).toBe(false);
    expect(wrapper.text()).toContain('1280 / 1280');
    await wrapper.setProps({
      targetInbox: { id: 7, channelType: 'Channel::Email' },
    });
    expect(wrapper.findComponent(FluxSmsCounter).exists()).toBe(false);
    expect(
      wrapper
        .findComponent({ name: 'ActionButtons' })
        .props('disableSendButton')
    ).toBe(false);
  });
});
