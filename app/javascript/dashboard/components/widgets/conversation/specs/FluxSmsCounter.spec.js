import { mount, config } from '@vue/test-utils';
import MessageApi from 'dashboard/api/inbox/message';
import FluxSmsCounter from '../FluxSmsCounter.vue';

vi.mock('dashboard/api/inbox/message', () => ({
  default: { previewSms: vi.fn(), previewNewSms: vi.fn() },
}));

describe('FluxSmsCounter exact server preview', () => {
  let wrapper;
  beforeEach(() => {
    vi.useFakeTimers();
    config.global.plugins[0].global.locale.value = 'pt_BR';
  });
  afterEach(() => {
    wrapper?.unmount();
    vi.clearAllTimers();
    vi.useRealTimers();
    config.global.plugins[0].global.locale.value = 'en';
  });

  it('shows zero and exact boundaries, without numbers while checking', async () => {
    wrapper = mount(FluxSmsCounter, {
      props: { content: '', conversationId: 1, accountId: 1, limit: 160 },
    });
    expect(wrapper.text()).toBe('0 / 160');
    MessageApi.previewSms.mockResolvedValueOnce({
      data: { length: 160, limit: 160, excess: 0, empty: false, valid: true },
    });
    await wrapper.setProps({ content: 'server renders 160' });
    expect(wrapper.text()).toContain('Verificando');
    expect(wrapper.text()).not.toContain(' / ');
    await vi.advanceTimersByTimeAsync(200);
    expect(wrapper.text()).toContain('160 / 160');
    expect(wrapper.text()).toContain('Limite de caracteres atingido.');
    MessageApi.previewSms.mockResolvedValueOnce({
      data: { length: 161, limit: 160, excess: 1, empty: false, valid: false },
    });
    await wrapper.setProps({ content: '{{contact.name}}' });
    await vi.advanceTimersByTimeAsync(200);
    expect(wrapper.text()).toContain('161 / 160');
    expect(wrapper.text()).toContain(
      'Mensagem acima do limite de 160 caracteres. Reduza o texto para enviar.'
    );
    expect(wrapper.text()).toContain(
      'Caracteres que precisam ser removidos: 1.'
    );
    expect(wrapper.text()).toContain('variáveis expandidas');
  });

  it('shows no approximate count on failure and supports retry', async () => {
    MessageApi.previewSms.mockRejectedValueOnce(new Error('offline'));
    wrapper = mount(FluxSmsCounter, {
      props: { content: 'Olá 😀', conversationId: 1, accountId: 1, limit: 160 },
    });
    await vi.advanceTimersByTimeAsync(200);
    expect(wrapper.text()).toContain('Não foi possível verificar');
    expect(wrapper.text()).not.toContain(' / ');
    MessageApi.previewSms.mockResolvedValueOnce({
      data: { length: 5, limit: 160, excess: 0, empty: false, valid: true },
    });
    await wrapper.find('button').trigger('click');
    await vi.advanceTimersByTimeAsync(0);
    expect(wrapper.text()).toContain('5 / 160');
  });

  it('ignores stale responses after editing and conversation changes', async () => {
    let oldResponse;
    MessageApi.previewSms.mockReturnValueOnce(
      new Promise(resolve => {
        oldResponse = resolve;
      })
    );
    wrapper = mount(FluxSmsCounter, {
      props: { content: 'old', conversationId: 1, accountId: 1, limit: 160 },
    });
    await vi.advanceTimersByTimeAsync(200);
    MessageApi.previewSms.mockResolvedValueOnce({
      data: { length: 4, limit: 1280, excess: 0, empty: false, valid: true },
    });
    await wrapper.setProps({ content: 'novo', conversationId: 2, limit: 1280 });
    await vi.advanceTimersByTimeAsync(200);
    oldResponse({
      data: { length: 999, limit: 160, excess: 839, valid: false },
    });
    await vi.advanceTimersByTimeAsync(0);
    expect(wrapper.text()).toContain('4 / 1280');
    expect(wrapper.text()).not.toContain('999');
    expect(wrapper.emitted('validation').at(-1)[0].conversationId).toBe(2);
  });

  it('reports a message that becomes empty after expansion', async () => {
    MessageApi.previewSms.mockResolvedValueOnce({
      data: { length: 0, limit: 160, excess: 0, empty: true, valid: false },
    });
    wrapper = mount(FluxSmsCounter, {
      props: {
        content: '{{contact.missing}}',
        conversationId: 1,
        accountId: 1,
        limit: 160,
      },
    });
    await vi.advanceTimersByTimeAsync(200);
    expect(wrapper.text()).toContain('vazia após expandir');
    expect(wrapper.emitted('validation').at(-1)[0].valid).toBe(false);
  });

  it('previews a new conversation with its selected contact, inbox and source', async () => {
    MessageApi.previewNewSms.mockResolvedValueOnce({
      data: { length: 161, limit: 160, excess: 1, empty: false, valid: false },
    });
    wrapper = mount(FluxSmsCounter, {
      props: {
        content: '{{contact.name}}',
        accountId: 2,
        inboxId: 3,
        contactId: 4,
        sourceId: '+5511999999999',
        variables: { name: 'Ana' },
      },
    });
    await vi.advanceTimersByTimeAsync(200);
    expect(MessageApi.previewNewSms).toHaveBeenCalledWith(
      expect.objectContaining({
        inboxId: 3,
        contactId: 4,
        sourceId: '+5511999999999',
        content: '{{contact.name}}',
      })
    );
    expect(MessageApi.previewSms).not.toHaveBeenCalled();
    expect(wrapper.text()).toContain('161 / 160');
  });

  it('does not invent a limit for an empty editor with an old inbox cache', async () => {
    MessageApi.previewNewSms.mockResolvedValueOnce({
      data: { length: 0, limit: 160, excess: 0, empty: true, valid: false },
    });
    wrapper = mount(FluxSmsCounter, {
      props: { content: '', accountId: 2, inboxId: 3, contactId: 4 },
    });
    expect(wrapper.text()).not.toContain(' / ');
    await vi.advanceTimersByTimeAsync(200);
    expect(wrapper.text()).toBe('0 / 160');
  });

  it('does not display a definitive count when the conversation ID does not exist yet', async () => {
    MessageApi.previewNewSms.mockResolvedValueOnce({
      data: { limit: 160, valid: false, reason: 'conversation_not_created' },
    });
    wrapper = mount(FluxSmsCounter, {
      props: {
        content: '{{conversation.id}}',
        accountId: 2,
        inboxId: 3,
        contactId: 4,
      },
    });
    await vi.advanceTimersByTimeAsync(200);
    expect(wrapper.text()).toContain('Não é possível confirmar o tamanho');
    expect(wrapper.text()).not.toContain(' / ');
    expect(wrapper.emitted('validation').at(-1)[0].valid).toBe(false);
  });

  it('ignores inverted results after changing contact, account and inbox', async () => {
    let stale;
    MessageApi.previewNewSms.mockReturnValueOnce(
      new Promise(resolve => {
        stale = resolve;
      })
    );
    wrapper = mount(FluxSmsCounter, {
      props: {
        content: '{{contact.name}}',
        accountId: 2,
        inboxId: 3,
        contactId: 4,
      },
    });
    await vi.advanceTimersByTimeAsync(200);
    MessageApi.previewNewSms.mockResolvedValueOnce({
      data: { length: 5, limit: 160, excess: 0, empty: false, valid: true },
    });
    await wrapper.setProps({ accountId: 5, inboxId: 6, contactId: 7 });
    await vi.advanceTimersByTimeAsync(200);
    stale({
      data: { length: 161, limit: 160, excess: 1, empty: false, valid: false },
    });
    await vi.advanceTimersByTimeAsync(0);
    expect(wrapper.text()).toContain('5 / 160');
    expect(wrapper.emitted('validation').at(-1)[0]).toMatchObject({
      accountId: 5,
      inboxId: 6,
      contactId: 7,
    });
  });
});
