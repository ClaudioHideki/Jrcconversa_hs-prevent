import { shallowMount, flushPromises } from '@vue/test-utils';
import { createStore } from 'vuex';
import { reactive, ref } from 'vue';
import ChatList from '../ChatList.vue';

let route;
vi.mock('vue-router', () => ({
  useRoute: () => route,
  useRouter: () => ({ push: vi.fn() }),
}));
vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({ uiSettings: ref({}) }),
}));
vi.mock('shared/composables/useFilter', () => ({
  useFilter: () => ({
    initializeStatusAndAssigneeFilterToModal: vi.fn(),
    initializeInboxTeamAndLabelFilterToModal: vi.fn(),
  }),
}));
vi.mock('dashboard/composables/useConversationRequiredAttributes', () => ({
  useConversationRequiredAttributes: () => ({
    checkMissingAttributes: () => ({ hasMissing: false, missing: [] }),
  }),
}));

describe('ChatList navigation loading regression', () => {
  let store;
  let wrapper;
  let dispatch;
  beforeEach(async () => {
    route = reactive({
      query: {},
      params: { accountId: '1', inbox_id: '2', conversation_id: '1' },
    });
    const records = [{ id: 1 }, { id: 2 }];
    store = createStore({
      state: { records, error: false },
      getters: {
        getCurrentUser: () => ({
          id: 1,
          accounts: [
            { id: 1, role: 'administrator', permissions: ['administrator'] },
          ],
        }),
        getCurrentAccountId: () => 1,
        getFilteredConversations: state => state.records,
        getMineChats: state => () => state.records,
        getAllStatusChats: state => () => state.records,
        getUnAssignedChats: () => () => [],
        getParticipatingChats: () => () => [],
        getChatListLoadingStatus: () => false,
        getChatListErrorStatus: state => state.error,
        getSelectedInbox: () => 2,
        getAppliedConversationFiltersV2: () => [],
        getConversationById: state => id =>
          state.records.find(item => item.id === id),
        'conversationStats/getStats': () => ({ mineCount: 2, allCount: 2 }),
        'customViews/getConversationCustomViews': () => [],
        'customViews/getActiveFolderContactId': () => null,
        'agents/getAgents': () => [],
        'teams/getTeams': () => [],
        'teams/getTeam': () => () => ({}),
        'inboxes/getInboxes': () => [],
        'inboxes/getInbox': () => () => ({ id: 2, name: 'SMS_2' }),
        'campaigns/getAllCampaigns': () => [],
        'labels/getLabels': () => [],
        'contacts/getContact': () => () => ({}),
        'attributes/getAttributesByModel': () => () => [],
        'bulkActions/getSelectedConversationIds': () => [],
        'conversationPage/getCurrentPageFilter': () => () => 0,
        'conversationPage/getHasEndReached': () => () => false,
      },
      actions: {
        fetchAllConversations: ({ state }) => {
          state.records = records;
          return true;
        },
        emptyAllConversations: ({ state }) => {
          state.records = [];
        },
        setChatListFilters: vi.fn(),
        setChatStatusFilter: vi.fn(),
        setChatSortFilter: vi.fn(),
        updateChatListFilters: vi.fn(),
        clearConversationFilters: vi.fn(),
        'conversationPage/reset': vi.fn(),
        'bulkActions/clearSelectedConversationIds': vi.fn(),
      },
    });
    wrapper = shallowMount(ChatList, {
      props: { conversationInbox: 2 },
      global: { plugins: [store] },
    });
    await flushPromises();
    dispatch = vi.spyOn(store, 'dispatch');
  });
  afterEach(() => wrapper?.unmount());

  it('preserves the list when changing conversation IDs with an equivalent query object', async () => {
    route.params.conversation_id = '2';
    route.query = {};
    await flushPromises();
    route.params.conversation_id = '1';
    route.query = {};
    await flushPromises();
    expect(dispatch).not.toHaveBeenCalledWith('emptyAllConversations');
    expect(dispatch).not.toHaveBeenCalledWith('fetchAllConversations');
    expect(store.state.records).toHaveLength(2);
  });

  it('does not reload the list for a message anchor', async () => {
    route.query = { messageId: '123' };
    await flushPromises();
    expect(dispatch).not.toHaveBeenCalledWith('emptyAllConversations');
    expect(dispatch).not.toHaveBeenCalledWith('fetchAllConversations');
  });

  it('still reloads when a real list filter changes', async () => {
    route.query = { status: 'resolved' };
    await flushPromises();
    expect(dispatch).toHaveBeenCalledWith('emptyAllConversations');
    expect(dispatch).toHaveBeenCalledWith('fetchAllConversations');
  });

  it('shows a recoverable list error without removing records', async () => {
    store.state.error = true;
    await flushPromises();
    expect(wrapper.find('[role="alert"]').exists()).toBe(true);
    await wrapper.find('[role="alert"] button').trigger('click');
    expect(dispatch).toHaveBeenCalledWith('fetchAllConversations');
    expect(store.state.records).toHaveLength(2);
  });
});
