import { shallowMount, flushPromises } from '@vue/test-utils';
import { createStore } from 'vuex';
import { ref, reactive } from 'vue';
import MessageApi from 'dashboard/api/inbox/message';
import ReplyBox from '../ReplyBox.vue';
import FluxSmsCounter from '../FluxSmsCounter.vue';
import { REPLY_EDITOR_MODES } from '../../WootWriter/constants';

vi.mock('dashboard/api/inbox/message', () => ({
  default: { previewSms: vi.fn() },
}));
vi.mock('dashboard/composables', async original => ({
  ...(await original()),
  useAlert: vi.fn(),
  useTrack: vi.fn(),
}));
vi.mock('dashboard/composables/useCopilotReply', () => ({
  useCopilotReply: () => ({
    isActive: ref(false),
    isButtonDisabled: ref(false),
    editorTransitionKey: ref('test'),
    reset: vi.fn(),
  }),
}));
vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    uiSettings: ref({}),
    isEditorHotKeyEnabled: () => true,
    fetchSignatureFlagFromUISettings: () => false,
    fetchQuotedReplyFlagFromUISettings: () => false,
    setQuotedReplyFlagForInbox: vi.fn(),
  }),
}));

describe('ReplyBox Flux SMS sending', () => {
  let wrapper;
  let inbox;
  let chat;
  let send;
  let drafts;
  beforeEach(() => {
    vi.useFakeTimers();
    inbox = reactive({
      id: 1,
      channel_type: 'Channel::Sms',
      provider: 'flux',
      sms_character_limit: 160,
    });
    chat = reactive({
      id: 1,
      inbox_id: 1,
      can_reply: true,
      messages: [],
      meta: {},
    });
    drafts = reactive({});
    send = vi.fn().mockResolvedValue(undefined);
    const store = createStore({
      getters: {
        getSelectedChat: () => chat,
        getCurrentUser: () => ({ id: 1, name: 'Agent' }),
        getCurrentAccountId: () => 1,
        getMessageSignature: () => '',
        getLastEmailInSelectedChat: () => null,
        'globalConfig/get': () => ({}),
        'inboxes/getInbox': () => () => inbox,
        'inboxes/getWhatsAppTemplates': () => () => [],
        'draftMessages/get': () => key => drafts[key] || '',
      },
      actions: {
        'draftMessages/set': (_, { key, message }) => {
          drafts[key] = message;
        },
        'draftMessages/delete': (_, { key }) => {
          delete drafts[key];
        },
        createPendingMessageAndSend: send,
      },
    });
    MessageApi.previewSms.mockResolvedValue({
      data: { length: 5, limit: 160, excess: 0, empty: false, valid: true },
    });
    wrapper = shallowMount(ReplyBox, {
      global: {
        plugins: [store],
        stubs: {
          FluxSmsCounter: false,
          'woot-confirm-modal': true,
          transition: { template: '<div><slot /></div>' },
        },
        directives: { 'on-clickaway': () => {} },
      },
    });
  });
  afterEach(() => {
    wrapper.unmount();
    vi.clearAllTimers();
    vi.useRealTimers();
  });

  it.each(
    ['a', 'é', '😀', '^', '€'].flatMap(character =>
      [159, 160, 161].map(length => ({ character, length }))
    )
  )(
    'uses server count for $length occurrences of $character',
    async ({ character, length }) => {
      MessageApi.previewSms.mockResolvedValueOnce({
        data: {
          length,
          limit: 160,
          excess: Math.max(length - 160, 0),
          empty: false,
          valid: length <= 160,
        },
      });
      const message = character.repeat(length);
      await wrapper.setData({ message });
      expect(wrapper.vm.isReplyButtonDisabled).toBe(true);
      expect(wrapper.vm.fluxSmsLength).toBeNull();
      await vi.advanceTimersByTimeAsync(200);
      expect(wrapper.vm.fluxSmsLength).toBe(length);
      expect(wrapper.vm.isReplyButtonDisabled).toBe(length > 160);
      expect(wrapper.vm.message).toBe(message);
    }
  );

  it('AUDIT: sends the Unicode URL counted as 160 by the backend', async () => {
    const message = `${'a'.repeat(131)} [JRC](https://exemplo.com/ação)`;
    MessageApi.previewSms.mockResolvedValueOnce({
      data: { length: 160, limit: 160, excess: 0, empty: false, valid: true },
    });
    await wrapper.setData({ message });
    await vi.advanceTimersByTimeAsync(200);
    expect(MessageApi.previewSms).toHaveBeenCalledWith({
      conversationId: 1,
      accountId: 1,
      content: message,
    });
    expect(wrapper.vm.fluxSmsLength).toBe(160);
    expect(wrapper.vm.isReplyButtonDisabled).toBe(false);
  });

  it('AUDIT: shows the final count for unresolved Liquid variables', async () => {
    MessageApi.previewSms.mockResolvedValueOnce({
      data: { length: 161, limit: 160, excess: 1, empty: false, valid: false },
    });
    await wrapper.setData({ message: '{{contact.name}}' });
    expect(wrapper.vm.fluxSmsLength).toBeNull();
    await vi.advanceTimersByTimeAsync(200);
    expect(wrapper.vm.fluxSmsLength).toBe(161);
    expect(wrapper.vm.isReplyButtonDisabled).toBe(true);
    expect(wrapper.findComponent(FluxSmsCounter).text()).toContain('161 / 160');
    expect(wrapper.vm.message).toBe('{{contact.name}}');
  });

  it.each([422, 429, 500, 'network'])(
    'AUDIT: preserves the draft after %s',
    async status => {
      const message = 'Olá {{contact.name}} 😀';
      await wrapper.setData({ message });
      await vi.advanceTimersByTimeAsync(200);
      send.mockRejectedValueOnce(
        status === 'network'
          ? new Error('offline')
          : { response: { status, data: { error: 'Rejected' } } }
      );
      await wrapper.vm.confirmOnSendReply();
      expect(send).toHaveBeenCalledTimes(1);
      expect(wrapper.vm.message).toBe(message);
      expect(drafts['draft-1-REPLY']).toBe(message);
      expect(wrapper.vm.isSendingCurrentDraft).toBe(false);
    }
  );

  it('clears only after HTTP success and blocks repeated clicks/Enter while pending', async () => {
    let resolve;
    await wrapper.setData({ message: 'texto' });
    await vi.advanceTimersByTimeAsync(200);
    send.mockReturnValueOnce(
      new Promise(done => {
        resolve = done;
      })
    );
    const request = wrapper.vm.confirmOnSendReply();
    expect(wrapper.vm.message).toBe('texto');
    expect(wrapper.vm.isReplyButtonDisabled).toBe(true);
    await wrapper.vm.confirmOnSendReply();
    expect(send).toHaveBeenCalledTimes(1);
    resolve();
    await request;
    await flushPromises();
    expect(wrapper.vm.message).toBe('');
    expect(drafts['draft-1-REPLY']).toBeUndefined();
  });

  it('keeps new edits when an earlier submission succeeds', async () => {
    let resolve;
    await wrapper.setData({ message: 'texto' });
    await vi.advanceTimersByTimeAsync(200);
    send.mockReturnValueOnce(
      new Promise(done => {
        resolve = done;
      })
    );
    const request = wrapper.vm.confirmOnSendReply();
    await wrapper.setData({ message: 'novo rascunho' });
    resolve();
    await request;
    expect(wrapper.vm.message).toBe('novo rascunho');
    expect(drafts['draft-1-REPLY']).toBe('novo rascunho');
  });

  it('does not clear another conversation when the previous send completes', async () => {
    let resolve;
    await wrapper.setData({ message: 'texto' });
    await vi.advanceTimersByTimeAsync(200);
    send.mockReturnValueOnce(
      new Promise(done => {
        resolve = done;
      })
    );
    const request = wrapper.vm.confirmOnSendReply();
    chat.id = 2;
    await flushPromises();
    await wrapper.setData({ message: 'rascunho B' });
    resolve();
    await request;
    expect(wrapper.vm.message).toBe('rascunho B');
    expect(drafts['draft-1-REPLY']).toBeUndefined();
  });

  it('automatically recovers at 160 and keeps over-limit drafts intact', async () => {
    MessageApi.previewSms.mockResolvedValueOnce({
      data: { length: 161, limit: 160, excess: 1, empty: false, valid: false },
    });
    await wrapper.setData({ message: '😀'.repeat(161) });
    await vi.advanceTimersByTimeAsync(200);
    await wrapper.vm.confirmOnSendReply();
    expect(send).not.toHaveBeenCalled();
    wrapper.vm.saveDraft(1, 'REPLY');
    expect(drafts['draft-1-REPLY']).toBe('😀'.repeat(161));
    MessageApi.previewSms.mockResolvedValueOnce({
      data: { length: 160, limit: 160, excess: 0, empty: false, valid: true },
    });
    await wrapper.setData({ message: '😀'.repeat(160) });
    await vi.advanceTimersByTimeAsync(200);
    expect(wrapper.vm.isReplyButtonDisabled).toBe(false);
  });

  it('preserves non-Flux channels and private notes', async () => {
    inbox.provider = 'bandwidth';
    await wrapper.setData({ message: 'a'.repeat(161) });
    expect(wrapper.findComponent(FluxSmsCounter).exists()).toBe(false);
    expect(wrapper.vm.isReplyButtonDisabled).toBe(false);
    await wrapper.setData({ replyType: REPLY_EDITOR_MODES.NOTE });
    await wrapper.setData({ message: 'a'.repeat(161) });
    expect(wrapper.vm.isReplyButtonDisabled).toBe(false);
    expect(MessageApi.previewSms).not.toHaveBeenCalled();
  });

  it('refreshes the exact count after a server validation refusal', async () => {
    await wrapper.setData({ message: '{{contact.name}}' });
    await vi.advanceTimersByTimeAsync(200);
    MessageApi.previewSms.mockResolvedValueOnce({
      data: { length: 161, limit: 160, excess: 1, empty: false, valid: false },
    });
    send.mockRejectedValueOnce({
      response: { status: 422, data: { error: 'over limit' } },
    });
    await wrapper.vm.confirmOnSendReply();
    await flushPromises();
    expect(wrapper.vm.fluxSmsLength).toBe(161);
    expect(wrapper.vm.isReplyButtonDisabled).toBe(true);
    expect(wrapper.vm.message).toBe('{{contact.name}}');
  });

  it.each(['Channel::Email', 'Channel::Whatsapp', 'Channel::Api'])(
    'keeps %s drafts on failure',
    async channelType => {
      inbox.channel_type = channelType;
      await wrapper.setData({
        message: 'draft',
        ccEmails: 'a@example.invalid',
        toEmails: 'b@example.invalid',
      });
      send.mockRejectedValueOnce({
        response: { status: 500, data: { error: 'server' } },
      });
      await wrapper.vm.confirmOnSendReply();
      expect(wrapper.vm.message).toBe('draft');
      expect(wrapper.vm.ccEmails).toBe('a@example.invalid');
      expect(wrapper.vm.toEmails).toBe('b@example.invalid');
      expect(MessageApi.previewSms).not.toHaveBeenCalled();
    }
  );

  it('keeps only failed WhatsApp attachments after partial success', async () => {
    inbox.channel_type = 'Channel::TwilioSms';
    inbox.medium = 'whatsapp';
    inbox.provider = 'default';
    const first = { resource: { file: new Blob(['first']) } };
    const second = { resource: { file: new Blob(['second']) } };
    await wrapper.setData({
      message: 'caption',
      attachedFiles: [first, second],
    });
    send
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(new Error('offline'));
    await wrapper.vm.confirmOnSendReply();
    expect(send).toHaveBeenCalledTimes(2);
    expect(wrapper.vm.message).toBe('');
    expect(wrapper.vm.attachedFiles).toHaveLength(1);
    expect(wrapper.vm.attachedFiles[0].resource.file).toBe(
      second.resource.file
    );
  });
});
