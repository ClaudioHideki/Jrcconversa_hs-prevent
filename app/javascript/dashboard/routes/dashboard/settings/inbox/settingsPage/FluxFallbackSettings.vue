<script setup>
import { computed, ref, watch } from 'vue';
import { useStore } from 'vuex';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import SettingsFieldSection from 'dashboard/components-next/Settings/SettingsFieldSection.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

const props = defineProps({ inbox: { type: Object, required: true } });
const store = useStore();
const { t } = useI18n();
const selectedInboxId = ref('');
const saving = ref(false);
const fluxInboxes = computed(() =>
  store.getters.getInboxes.filter(
    inbox => inbox.channel_type === 'Channel::Sms' && inbox.provider === 'flux'
  )
);

watch(
  () => props.inbox.flux_fallback_inbox_id,
  value => {
    selectedInboxId.value = value ? String(value) : '';
  },
  { immediate: true }
);

async function save() {
  saving.value = true;
  try {
    await store.dispatch('inboxes/updateInbox', {
      id: props.inbox.id,
      formData: false,
      channel: { flux_fallback_inbox_id: selectedInboxId.value || null },
    });
    useAlert(t('INBOX_MGMT.EDIT.API.SUCCESS_MESSAGE'));
  } catch (error) {
    useAlert(
      error.response?.data?.message || t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE')
    );
  } finally {
    saving.value = false;
  }
}
</script>

<template>
  <SettingsFieldSection
    :label="$t('INBOX_MGMT.FLUX_FALLBACK.TITLE')"
    :help-text="$t('INBOX_MGMT.FLUX_FALLBACK.DESCRIPTION')"
  >
    <div class="flex w-full flex-col gap-3">
      <label class="text-sm text-n-slate-12">
        {{ $t('INBOX_MGMT.FLUX_FALLBACK.INBOX') }}
        <select v-model="selectedInboxId" class="mt-2 w-full">
          <option value="">
            {{ $t('INBOX_MGMT.FLUX_FALLBACK.DISABLED') }}
          </option>
          <option
            v-for="fluxInbox in fluxInboxes"
            :key="fluxInbox.id"
            :value="String(fluxInbox.id)"
          >
            {{ fluxInbox.name }}
          </option>
        </select>
      </label>
      <p class="text-sm text-n-slate-11">
        {{ $t('INBOX_MGMT.FLUX_FALLBACK.NOTICE') }}
      </p>
      <p v-if="!fluxInboxes.length" class="text-sm text-n-slate-11">
        {{ $t('INBOX_MGMT.FLUX_FALLBACK.EMPTY') }}
      </p>
      <NextButton
        :label="$t('INBOX_MGMT.SETTINGS_POPUP.UPDATE')"
        :is-loading="saving"
        class="self-start"
        @click="save"
      />
    </div>
  </SettingsFieldSection>
</template>
