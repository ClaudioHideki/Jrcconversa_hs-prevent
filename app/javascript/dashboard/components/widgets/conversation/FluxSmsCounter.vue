<script setup>
import { ref, watch, onBeforeUnmount } from 'vue';
import { useI18n } from 'vue-i18n';
import MessageApi from 'dashboard/api/inbox/message';

const props = defineProps({
  content: { type: String, required: true },
  conversationId: { type: [Number, String], default: null },
  inboxId: { type: Number, default: null },
  contactId: { type: [Number, String], default: null },
  sourceId: { type: String, default: null },
  accountId: { type: Number, required: true },
  variables: { type: Object, default: () => ({}) },
  limit: { type: Number, default: null },
});
const emit = defineEmits(['validation']);
const { t } = useI18n();
const result = ref(null);
const status = ref('pending');
let revision = 0;
let timer;

function publish(snapshot, nextStatus, data = null) {
  status.value = nextStatus;
  result.value = data;
  emit('validation', { ...snapshot, status: nextStatus, ...data });
}

async function fetchPreview(snapshot, request) {
  try {
    const { data } = await (snapshot.conversationId
      ? MessageApi.previewSms(snapshot)
      : MessageApi.previewNewSms(snapshot));
    if (request === revision) publish(snapshot, 'ready', data);
  } catch {
    if (request === revision) publish(snapshot, 'error');
  }
}

function validate(immediate = false) {
  clearTimeout(timer);
  revision += 1;
  const request = revision;
  const snapshot = {
    conversationId: props.conversationId,
    accountId: props.accountId,
    content: props.content,
    inboxId: props.inboxId,
    variablesKey: JSON.stringify(props.variables),
  };
  if (!props.conversationId) {
    snapshot.inboxId = props.inboxId;
    snapshot.contactId = props.contactId;
    snapshot.sourceId = props.sourceId;
  }
  publish(snapshot, 'pending');
  if (props.content === '' && Number.isFinite(props.limit)) {
    publish(snapshot, 'ready', {
      length: 0,
      limit: props.limit,
      excess: 0,
      empty: true,
      valid: false,
    });
  } else if (immediate) {
    fetchPreview(snapshot, request);
  } else {
    timer = setTimeout(() => fetchPreview(snapshot, request), 200);
  }
}

watch(
  [
    () => props.content,
    () => props.conversationId,
    () => props.inboxId,
    () => props.contactId,
    () => props.sourceId,
    () => props.accountId,
    () => props.limit,
    () => props.variables,
  ],
  () => validate(),
  { immediate: true, deep: true }
);
onBeforeUnmount(() => {
  clearTimeout(timer);
  revision += 1;
});
defineExpose({ refresh: () => validate(true) });
</script>

<template>
  <div
    class="px-3 py-2 text-xs"
    :class="
      status === 'error' || result?.excess
        ? 'text-n-ruby-11'
        : 'text-n-slate-11'
    "
    role="status"
    aria-live="polite"
    aria-atomic="true"
    data-testid="flux-sms-counter"
  >
    <span v-if="status === 'pending'">{{
      t('CONVERSATION.FLUX_SMS_LIMIT.CHECKING')
    }}</span>
    <template v-else-if="status === 'error'">
      {{ t('CONVERSATION.FLUX_SMS_LIMIT.CHECK_ERROR') }}
      <button type="button" class="ml-2 underline" @click="validate(true)">
        {{ t('CONVERSATION.FLUX_SMS_LIMIT.RETRY') }}
      </button>
    </template>
    <p v-else-if="result?.reason === 'conversation_not_created'">
      {{ t('CONVERSATION.FLUX_SMS_LIMIT.UNAVAILABLE_CONVERSATION') }}
    </p>
    <template v-else>
      <span class="font-medium">{{
        `${result.length} / ${result.limit}`
      }}</span>
      <template v-if="result.excess">
        <p class="mt-1">
          {{
            t('CONVERSATION.FLUX_SMS_LIMIT.EXCEEDED', { limit: result.limit })
          }}
        </p>
        <p class="mt-1">
          {{
            t('CONVERSATION.FLUX_SMS_LIMIT.REMOVE', { count: result.excess })
          }}
        </p>
      </template>
      <span
        v-else-if="result.length === result.limit"
        class="ml-2 text-n-amber-11"
      >
        {{ t('CONVERSATION.FLUX_SMS_LIMIT.REACHED') }}
      </span>
      <p v-if="content" class="mt-1">
        {{
          result.empty
            ? t('CONVERSATION.FLUX_SMS_LIMIT.EMPTY')
            : t('CONVERSATION.FLUX_SMS_LIMIT.EXPANDED')
        }}
      </p>
    </template>
  </div>
</template>
