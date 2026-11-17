import { config, mount } from '@vue/test-utils';
import { ref } from 'vue';
import MessageMeta from '../MessageMeta.vue';
import MessageStatus from '../MessageStatus.vue';
import MessageError from '../MessageError.vue';
import { fluxFailureReason } from '../fluxFailureReason';
import { useMessageContext } from '../provider';
import { useInbox } from 'dashboard/composables/useInbox';

vi.mock('../provider', () => ({ useMessageContext: vi.fn() }));
vi.mock('dashboard/composables/useInbox', () => ({ useInbox: vi.fn() }));

describe('Flux delivery and rejection display', () => {
  let context;
  let channels;
  const options = () => ({
    global: {
      stubs: { Icon: { props: ['icon'], template: '<i :data-icon="icon" />' } },
    },
  });

  beforeEach(() => {
    config.global.plugins[0].global.locale.value = 'pt_BR';
    context = {
      status: ref('sent'),
      sourceId: ref('1234567'),
      messageType: ref(1),
      isPrivate: ref(false),
      createdAt: ref(Date.now() / 1000),
      orientation: ref('right'),
      content: ref('SMS test'),
      attachments: ref([]),
      contentAttributes: ref({ fluxPartnerId: 'JRC-SMS-1' }),
      isFluxSms: ref(true),
    };
    channels = Object.fromEntries(
      [
        'isAFacebookInbox',
        'isALineChannel',
        'isAPIInbox',
        'isASmsInbox',
        'isATelegramChannel',
        'isATwilioChannel',
        'isAWebWidgetInbox',
        'isAWhatsAppChannel',
        'isAnEmailChannel',
        'isAnInstagramChannel',
        'isATiktokChannel',
      ].map(key => [key, ref(key === 'isASmsInbox')])
    );
    useMessageContext.mockReturnValue(context);
    useInbox.mockReturnValue(channels);
  });

  afterEach(() => {
    config.global.plugins[0].global.locale.value = 'en';
  });

  it('shows one check for acceptance and two only after an actual status update', async () => {
    const wrapper = mount(MessageMeta, options());
    expect(wrapper.getComponent(MessageStatus).props('status')).toBe('sent');
    expect(wrapper.find('[data-icon="i-lucide-check"]').exists()).toBe(true);
    expect(wrapper.getComponent(MessageStatus).props('sentTooltip')).toBe(
      'Aguardando confirmação de entrega'
    );
    context.status.value = 'delivered';
    await wrapper.vm.$nextTick();
    expect(wrapper.find('[data-icon="i-lucide-check-check"]').exists()).toBe(
      true
    );
    expect(wrapper.getComponent(MessageStatus).props('status')).toBe(
      'delivered'
    );
    context.status.value = 'failed';
    await wrapper.vm.$nextTick();
    expect(wrapper.findComponent(MessageStatus).exists()).toBe(false);
  });

  it('never presents Flux as read, nor acceptance without a provider id as sent', () => {
    context.status.value = 'read';
    const wrapper = mount(MessageMeta, options());
    expect(wrapper.getComponent(MessageStatus).props('status')).not.toBe(
      'read'
    );
    wrapper.unmount();
    context.status.value = 'sent';
    context.sourceId.value = null;
    const pending = mount(MessageMeta, options());
    expect(pending.getComponent(MessageStatus).props('status')).toBe(
      'progress'
    );
  });

  it.each([
    ['EM ANALISE', 'Em análise na Flux'],
    [' em análise ', 'Em análise na Flux'],
    ['EM ANALISE DE ENVIO PARA OPERADORA', 'Em análise na Flux'],
    ['ANALISE OPERADORA', 'Em análise na Flux'],
    ['ENVIADA', 'Enviada pela Flux'],
    ['ACEITA', 'Aceita pela Flux'],
    ['Agendado', 'Agendada na Flux'],
    [
      'ANALISE LINK (APROVACAO EM ANDAMENTO AGUARDAR)',
      'Link em análise na Flux',
    ],
    ['UNKNOWN', 'Aguardando confirmação de entrega'],
    ['ENTREGUE', 'Aguardando confirmação de entrega'],
  ])(
    'labels the last received state %s without claiming delivery',
    (state, label) => {
      context.contentAttributes.value = { fluxStatus: state };
      const wrapper = mount(MessageMeta, options());
      expect(wrapper.get('[data-testid="flux-delivery-label"]').text()).toBe(
        label
      );
      expect(wrapper.find('[data-icon="i-lucide-check-check"]').exists()).toBe(
        false
      );
    }
  );

  it('updates the visible label from analysis to sent and actual delivery', async () => {
    context.contentAttributes.value = { fluxStatus: 'EM ANALISE' };
    const wrapper = mount(MessageMeta, options());
    expect(wrapper.text()).toContain('Em análise na Flux');
    context.contentAttributes.value = { fluxStatus: 'ENVIADA' };
    await wrapper.vm.$nextTick();
    expect(wrapper.text()).toContain('Enviada pela Flux');
    context.contentAttributes.value = { fluxStatus: 'ENTREGUE' };
    context.status.value = 'delivered';
    await wrapper.vm.$nextTick();
    expect(wrapper.get('[data-testid="flux-delivery-label"]').text()).toBe(
      'Entregue'
    );
    expect(wrapper.find('[data-icon="i-lucide-check-check"]').exists()).toBe(
      true
    );
    context.status.value = 'failed';
    await wrapper.vm.$nextTick();
    expect(wrapper.find('[data-testid="flux-delivery-label"]').exists()).toBe(
      false
    );
  });

  it.each(['private', 'incoming', 'deleted', 'other-channel'])(
    'does not add a Flux delivery label to %s messages',
    kind => {
      if (kind === 'private') context.isPrivate.value = true;
      if (kind === 'incoming') context.messageType.value = 0;
      if (kind === 'deleted')
        context.contentAttributes.value = { deleted: true };
      if (kind === 'other-channel') context.isFluxSms.value = false;
      const wrapper = mount(MessageMeta, options());
      expect(wrapper.find('[data-testid="flux-delivery-label"]').exists()).toBe(
        false
      );
    }
  );

  it.each([
    ['SPAM', 'Suspeita de spam.'],
    ['NUMERO INVALIDO', 'Número inválido.'],
    ['NUMERO BLOQUEADO', 'Número bloqueado.'],
    ['BLOQUEADA', 'Mensagem bloqueada.'],
    ['REJEITADA', 'Rejeitada pela operadora.'],
    ['EXPIRADA', 'Prazo de entrega expirado.'],
    ['NAO ENTREGUE', 'Mensagem não entregue.'],
    ['CARACTERES LIMITE EXCEDIDO', 'Limite de caracteres excedido.'],
  ])(
    'displays %s visibly and prevents one-click retry',
    (status, description) => {
      context.status.value = 'failed';
      context.contentAttributes.value = {
        fluxStatus: status,
        externalError: `Flux: ${status}`,
      };
      const wrapper = mount(MessageError, {
        ...options(),
        props: { error: `Flux: ${status}` },
      });
      expect(wrapper.text()).toContain(`Falhou — ${description}`);
      expect(wrapper.text()).toContain('evitar entrega duplicada');
      expect(wrapper.find('button').exists()).toBe(false);
    }
  );

  it('updates the rejection description reactively and provides an honest fallback', async () => {
    context.status.value = 'failed';
    const wrapper = mount(MessageError, { ...options(), props: { error: '' } });
    expect(wrapper.text()).toContain('Motivo não informado pelo provedor.');
    context.contentAttributes.value = {
      externalError: 'Flux 175: Mensagem classificada como spam',
    };
    await wrapper.vm.$nextTick();
    expect(wrapper.text()).toContain('Suspeita de spam.');
    context.contentAttributes.value = {
      externalError: 'Flux 999: Erro desconhecido',
    };
    await wrapper.vm.$nextTick();
    expect(wrapper.text()).toContain('Motivo não informado pelo provedor.');
  });

  it.each([
    'isAWhatsAppChannel',
    'isATwilioChannel',
    'isAPIInbox',
    'isAFacebookInbox',
  ])('preserves delivered and read for %s', async key => {
    context.isFluxSms.value = false;
    context.contentAttributes.value = {};
    channels.isASmsInbox.value = false;
    channels[key].value = true;
    context.status.value = 'delivered';
    const wrapper = mount(MessageMeta, options());
    expect(wrapper.getComponent(MessageStatus).props('status')).toBe(
      'delivered'
    );
    expect(wrapper.getComponent(MessageStatus).props('sentTooltip')).toBe('');
    context.status.value = 'read';
    await wrapper.vm.$nextTick();
    expect(wrapper.getComponent(MessageStatus).props('status')).toBe('read');
  });

  it('preserves the existing retry action and tooltip on other channels', async () => {
    context.isFluxSms.value = false;
    context.status.value = 'failed';
    const wrapper = mount(MessageError, {
      ...options(),
      props: { error: 'Original provider error' },
    });
    expect(wrapper.text()).toContain('Original provider error');
    await wrapper.get('button').trigger('click');
    expect(wrapper.emitted('retry')).toHaveLength(1);
  });

  it.each([
    [{ fluxStatus: 'Número Inválido' }, 'INVALID_NUMBER'],
    [{ externalError: 'Flux: SPAM' }, 'SPAM'],
    [
      { externalError: 'Flux: a mensagem deve conter de 1 a 160 caracteres.' },
      'CHARACTER_LIMIT',
    ],
    [
      { externalError: 'Flux: a mensagem deve conter de 1 a 1280 caracteres.' },
      'CHARACTER_LIMIT',
    ],
    [
      { externalError: 'Flux: informe um celular brasileiro com DDD.' },
      'INVALID_NUMBER',
    ],
    [{ externalError: 'Flux 013: Numero invalido' }, 'INVALID_NUMBER'],
    [{ externalError: 'Flux 161: Rejeitada' }, 'REJECTED'],
    [{ externalError: 'Flux 162: Bloqueada' }, 'BLOCKED'],
    [{ externalError: 'Flux 146: Nao entregue' }, 'UNDELIVERED'],
    [{ externalError: 'Flux 999: Unknown' }, 'UNKNOWN'],
    [
      {
        externalError:
          'Flux: configure FLUX_CALLBACK_BASE_URL com uma URL publica curta.',
      },
      'CALLBACK_CONFIGURATION',
    ],
    [
      {
        externalError:
          'Flux: URL de callback invalida. Verifique FLUX_CALLBACK_BASE_URL.',
      },
      'CALLBACK_CONFIGURATION',
    ],
    [{}, 'UNKNOWN'],
  ])(
    'handles existing records without rewriting their metadata: %j',
    (attributes, expected) => {
      const original = structuredClone(attributes);
      expect(fluxFailureReason(attributes)).toBe(expected);
      expect(attributes).toEqual(original);
    }
  );
});
