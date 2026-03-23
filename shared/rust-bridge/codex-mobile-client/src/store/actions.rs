use codex_app_server_protocol as upstream;

use crate::conversation::{ConversationItem, hydrate_thread_item};
use crate::types::ThreadInfo;

pub(crate) fn thread_info_from_upstream(thread: upstream::Thread) -> ThreadInfo {
    ThreadInfo::from(thread)
}

pub(crate) fn thread_info_from_upstream_status_change(
    thread_id: &str,
    status: upstream::ThreadStatus,
) -> ThreadInfo {
    ThreadInfo {
        id: thread_id.to_string(),
        title: None,
        model: None,
        status: status.into(),
        preview: None,
        cwd: None,
        path: None,
        model_provider: None,
        agent_nickname: None,
        agent_role: None,
        parent_thread_id: None,
        agent_status: None,
        created_at: None,
        updated_at: None,
    }
}

pub(crate) fn conversation_item_from_upstream(item: upstream::ThreadItem) -> Option<ConversationItem> {
    hydrate_thread_item(&item, None, None, &Default::default())
}
