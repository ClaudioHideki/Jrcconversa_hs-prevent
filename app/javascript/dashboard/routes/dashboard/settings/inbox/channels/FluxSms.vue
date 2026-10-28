<script setup>
import { computed, ref } from 'vue';
import { useStore } from 'vuex';
import { useI18n } from 'vue-i18n';
import { useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import FluxChannel from 'dashboard/api/channel/fluxChannel';
import NextButton from 'dashboard/components-next/button/Button.vue';

const props = defineProps({ inbox: { type: Object, default: null } });
const store = useStore();
const router = useRouter();
const { t } = useI18n();
const inboxName = ref(props.inbox?.name || '');
const account = ref('');
const code = ref('');
const sendType = ref(props.inbox?.provider_config?.send_type || '1');
const client = ref(props.inbox?.provider_config?.client || '');
const moPollingEnabled = ref(
  props.inbox?.provider_config?.mo_polling_enabled === true
);
const busy = ref(false);
const testing = ref(false);
const testResult = ref('');
const testFailed = ref(false);
const saveError = ref('');
const configured = computed(() => props.inbox?.provider_config?.configured);
const valid = computed(
  () =>
    inboxName.value.trim() &&
    (account.value.trim() || configured.value) &&
    (code.value || configured.value)
);

function credentials() {
  return {
    ...(account.value.trim() ? { flux_account: account.value.trim() } : {}),
    ...(code.value ? { flux_code: code.value } : {}),
  };
}

async function testConnection() {
  testing.value = true;
  testResult.value = '';
  try {
    await FluxChannel.testConnection({
      ...credentials(),
      inbox_id: props.inbox?.id,
    });
    testResult.value = t('INBOX_MGMT.ADD.SMS.FLUX.TEST_SUCCESS');
    testFailed.value = false;
  } catch (error) {
    testResult.value =
      error.response?.data?.error || t('INBOX_MGMT.ADD.SMS.FLUX.ERROR');
    testFailed.value = true;
  } finally {
    testing.value = false;
  }
}

async function save() {
  if (!valid.value) return;
  busy.value = true;
  saveError.value = '';
  try {
    const channel = {
      ...(!props.inbox ? { type: 'sms', provider: 'flux' } : {}),
      ...credentials(),
      provider_config: {
        send_type: sendType.value,
        client: client.value.trim(),
        mo_polling_enabled: moPollingEnabled.value,
      },
    };
    if (props.inbox) {
      await store.dispatch('inboxes/updateInbox', {
        id: props.inbox.id,
        formData: false,
        name: inboxName.value.trim(),
        channel,
      });
      account.value = '';
      code.value = '';
      useAlert(t('INBOX_MGMT.ADD.SMS.FLUX.SAVED'));
    } else {
      const result = await store.dispatch('inboxes/createChannel', {
        name: inboxName.value.trim(),
        channel,
      });
      await router.replace({
        name: 'settings_inboxes_add_agents',
        params: { page: 'new', inbox_id: result.id },
      });
    }
  } catch (error) {
    saveError.value =
      error.response?.data?.message ||
      error.response?.data?.error ||
      error.message ||
      t('INBOX_MGMT.ADD.SMS.FLUX.SAVE_ERROR');
    useAlert(saveError.value);
  } finally {
    busy.value = false;
  }
}
</script>

<template>
  <form class="flex flex-col gap-2" @submit.prevent="save">
    <p class="mb-3 text-sm text-n-slate-11">
      {{ t('INBOX_MGMT.ADD.SMS.FLUX.DESCRIPTION') }}
    </p>
    <label>
      {{ t('INBOX_MGMT.ADD.SMS.FLUX.INBOX_NAME') }}
      <input
        v-model="inboxName"
        type="text"
        required
        :placeholder="t('INBOX_MGMT.ADD.SMS.FLUX.NAME_PLACEHOLDER')"
      />
    </label>
    <label>
      {{ t('INBOX_MGMT.ADD.SMS.FLUX.ACCOUNT') }}
      <input
        v-model="account"
        type="text"
        autocomplete="off"
        maxlength="100"
        :required="!configured"
        :placeholder="
          inbox?.provider_config?.account_masked ||
          t('INBOX_MGMT.ADD.SMS.FLUX.ACCOUNT_PLACEHOLDER')
        "
      />
    </label>
    <label>
      {{ t('INBOX_MGMT.ADD.SMS.FLUX.CODE') }}
      <input
        v-model="code"
        type="password"
        autocomplete="new-password"
        :required="!configured"
        :placeholder="
          configured
            ? t('INBOX_MGMT.ADD.SMS.FLUX.KEEP_SECRET')
            : t('INBOX_MGMT.ADD.SMS.FLUX.CODE_PLACEHOLDER')
        "
      />
    </label>
    <label>
      {{ t('INBOX_MGMT.ADD.SMS.FLUX.SEND_TYPE') }}
      <select v-model="sendType">
        <option value="1">{{ t('INBOX_MGMT.ADD.SMS.FLUX.TYPE_1') }}</option>
        <option value="2">{{ t('INBOX_MGMT.ADD.SMS.FLUX.TYPE_2') }}</option>
        <option value="4">{{ t('INBOX_MGMT.ADD.SMS.FLUX.TYPE_4') }}</option>
        <option value="7">{{ t('INBOX_MGMT.ADD.SMS.FLUX.TYPE_7') }}</option>
      </select>
    </label>
    <label>
      {{ t('INBOX_MGMT.ADD.SMS.FLUX.CLIENT') }}
      <input
        v-model="client"
        type="text"
        maxlength="200"
        :placeholder="t('INBOX_MGMT.ADD.SMS.FLUX.CLIENT_PLACEHOLDER')"
      />
    </label>
    <label class="flex items-center gap-2">
      <input v-model="moPollingEnabled" type="checkbox" />
      {{ t('INBOX_MGMT.ADD.SMS.FLUX.MO_POLLING') }}
    </label>
    <p class="text-sm text-n-slate-11">
      {{ t('INBOX_MGMT.ADD.SMS.FLUX.MO_POLLING_HELP') }}
    </p>
    <label v-if="inbox?.callback_webhook_url">
      {{ t('INBOX_MGMT.ADD.SMS.FLUX.CALLBACK') }}
      <input :value="inbox.callback_webhook_url" type="text" readonly />
    </label>
    <p class="text-sm text-n-slate-11">
      {{ t('INBOX_MGMT.ADD.SMS.FLUX.CALLBACK_HELP') }}
    </p>
    <p class="text-sm text-n-slate-11">
      {{ t('INBOX_MGMT.ADD.SMS.FLUX.IP_HELP') }}
    </p>
    <p
      v-if="testResult"
      role="status"
      :class="testFailed ? 'text-n-ruby-11' : 'text-n-teal-11'"
    >
      {{ testResult }}
    </p>
    <p v-if="saveError" role="alert" class="text-sm text-n-ruby-11">
      {{ saveError }}
    </p>
    <div class="mt-4 flex flex-wrap gap-3">
      <NextButton
        type="button"
        :label="t('INBOX_MGMT.ADD.SMS.FLUX.TEST')"
        :is-loading="testing"
        :disabled="!valid || busy"
        @click="testConnection"
      />
      <NextButton
        type="submit"
        :label="
          inbox
            ? t('INBOX_MGMT.ADD.SMS.FLUX.SAVE')
            : t('INBOX_MGMT.ADD.SMS.FLUX.CREATE')
        "
        :is-loading="busy"
        :disabled="!valid || testing"
      />
    </div>
  </form>
</template>
