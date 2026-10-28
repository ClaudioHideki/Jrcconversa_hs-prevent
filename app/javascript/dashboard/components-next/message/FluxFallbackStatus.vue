<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useMapGetter } from 'dashboard/composables/store';

const props = defineProps({ fallback: { type: Object, required: true } });
const { t } = useI18n();
const accountId = useMapGetter('getCurrentAccountId');
const inboxes = useMapGetter('getInboxes');
const canOpenConversation = computed(
  () =>
    props.fallback.conversationDisplayId &&
    inboxes.value.some(inbox => inbox.id === props.fallback.inboxId)
);
const label = computed(() => {
  if (props.fallback.state === 'skipped') {
    return props.fallback.reason === 'delivered'
      ? t('CONVERSATION.FLUX_FALLBACK.PRIMARY_DELIVERED')
      : t('CONVERSATION.FLUX_FALLBACK.SKIPPED');
  }
  const states = {
    waiting: t('CONVERSATION.FLUX_FALLBACK.WAITING'),
    sending: t('CONVERSATION.FLUX_FALLBACK.SENDING'),
    sent: t('CONVERSATION.FLUX_FALLBACK.SENT'),
    delivered: t('CONVERSATION.FLUX_FALLBACK.DELIVERED'),
    read: t('CONVERSATION.FLUX_FALLBACK.DELIVERED'),
    failed: t('CONVERSATION.FLUX_FALLBACK.FAILED'),
  };
  return (
    states[props.fallback.state] || t('CONVERSATION.FLUX_FALLBACK.SENDING')
  );
});
const reason = computed(() => {
  const reasons = {
    disabled: t('CONVERSATION.FLUX_FALLBACK.REASONS.DISABLED'),
    deleted: t('CONVERSATION.FLUX_FALLBACK.REASONS.DELETED'),
    primary_changed: t('CONVERSATION.FLUX_FALLBACK.REASONS.PRIMARY_CHANGED'),
    attachments: t('CONVERSATION.FLUX_FALLBACK.REASONS.ATTACHMENTS'),
    template_body: t('CONVERSATION.FLUX_FALLBACK.REASONS.TEMPLATE_BODY'),
    text_limit: t('CONVERSATION.FLUX_FALLBACK.REASONS.TEXT_LIMIT'),
    invalid_phone: t('CONVERSATION.FLUX_FALLBACK.REASONS.INVALID_PHONE'),
    opted_out: t('CONVERSATION.FLUX_FALLBACK.REASONS.OPTED_OUT'),
  };
  return reasons[props.fallback.reason] || null;
});
</script>

<template>
  <div class="mt-1 max-w-full text-xs text-n-slate-11" role="status">
    <span>{{ label }}</span>
    <span v-if="reason" class="ml-1">{{ reason }}</span>
    <span v-if="fallback.error" class="ml-1">{{ fallback.error }}</span>
    <router-link
      v-if="canOpenConversation"
      :to="{
        name: 'inbox_conversation',
        params: {
          accountId,
          conversation_id: fallback.conversationDisplayId,
        },
      }"
      class="ml-1 text-n-blue-11 underline"
    >
      {{ $t('CONVERSATION.FLUX_FALLBACK.OPEN') }}
    </router-link>
  </div>
</template>
