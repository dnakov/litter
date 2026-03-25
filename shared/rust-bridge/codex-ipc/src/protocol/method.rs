use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Method {
    Initialize,
    ClientStatusChanged,
    ExternalResumeThread,
    ThreadStreamStateChanged,
    ThreadArchived,
    ThreadUnarchived,
    ThreadFollowerStartTurn,
    ThreadFollowerSteerTurn,
    ThreadFollowerInterruptTurn,
    ThreadFollowerSetModelAndReasoning,
    ThreadFollowerSetCollaborationMode,
    ThreadFollowerEditLastUserTurn,
    ThreadFollowerCommandApprovalDecision,
    ThreadFollowerFileApprovalDecision,
    ThreadFollowerSubmitUserInput,
    ThreadFollowerSubmitMcpServerElicitationResponse,
    ThreadFollowerSetQueuedFollowUpsState,
    ThreadQueuedFollowupsChanged,
    QueryCacheInvalidate,
}

impl Method {
    pub fn wire_name(&self) -> &'static str {
        match self {
            Method::Initialize => "initialize",
            Method::ClientStatusChanged => "client-status-changed",
            Method::ExternalResumeThread => "external-resume-thread",
            Method::ThreadStreamStateChanged => "thread-stream-state-changed",
            Method::ThreadArchived => "thread-archived",
            Method::ThreadUnarchived => "thread-unarchived",
            Method::ThreadFollowerStartTurn => "thread-follower-start-turn",
            Method::ThreadFollowerSteerTurn => "thread-follower-steer-turn",
            Method::ThreadFollowerInterruptTurn => "thread-follower-interrupt-turn",
            Method::ThreadFollowerSetModelAndReasoning => "thread-follower-set-model-and-reasoning",
            Method::ThreadFollowerSetCollaborationMode => "thread-follower-set-collaboration-mode",
            Method::ThreadFollowerEditLastUserTurn => "thread-follower-edit-last-user-turn",
            Method::ThreadFollowerCommandApprovalDecision => {
                "thread-follower-command-approval-decision"
            }
            Method::ThreadFollowerFileApprovalDecision => "thread-follower-file-approval-decision",
            Method::ThreadFollowerSubmitUserInput => "thread-follower-submit-user-input",
            Method::ThreadFollowerSubmitMcpServerElicitationResponse => {
                "thread-follower-submit-mcp-server-elicitation-response"
            }
            Method::ThreadFollowerSetQueuedFollowUpsState => {
                "thread-follower-set-queued-follow-ups-state"
            }
            Method::ThreadQueuedFollowupsChanged => "thread-queued-followups-changed",
            Method::QueryCacheInvalidate => "query-cache-invalidate",
        }
    }

    pub fn current_version(&self) -> u32 {
        match self {
            Method::Initialize | Method::ExternalResumeThread => 1,
            Method::ThreadStreamStateChanged => 5,
            Method::ThreadArchived => 2,
            Method::ThreadUnarchived
            | Method::ThreadFollowerStartTurn
            | Method::ThreadFollowerSteerTurn
            | Method::ThreadFollowerInterruptTurn
            | Method::ThreadFollowerSetModelAndReasoning
            | Method::ThreadFollowerSetCollaborationMode
            | Method::ThreadFollowerEditLastUserTurn
            | Method::ThreadFollowerCommandApprovalDecision
            | Method::ThreadFollowerFileApprovalDecision
            | Method::ThreadFollowerSubmitUserInput
            | Method::ThreadFollowerSubmitMcpServerElicitationResponse
            | Method::ThreadFollowerSetQueuedFollowUpsState
            | Method::ThreadQueuedFollowupsChanged => 1,
            _ => 0,
        }
    }

    pub fn from_wire(s: &str) -> Option<Self> {
        match s {
            "initialize" => Some(Method::Initialize),
            "client-status-changed" => Some(Method::ClientStatusChanged),
            "external-resume-thread" => Some(Method::ExternalResumeThread),
            "thread-stream-state-changed" => Some(Method::ThreadStreamStateChanged),
            "thread-archived" => Some(Method::ThreadArchived),
            "thread-unarchived" => Some(Method::ThreadUnarchived),
            "thread-follower-start-turn" => Some(Method::ThreadFollowerStartTurn),
            "thread-follower-steer-turn" => Some(Method::ThreadFollowerSteerTurn),
            "thread-follower-interrupt-turn" => Some(Method::ThreadFollowerInterruptTurn),
            "thread-follower-set-model-and-reasoning" => {
                Some(Method::ThreadFollowerSetModelAndReasoning)
            }
            "thread-follower-set-collaboration-mode" => {
                Some(Method::ThreadFollowerSetCollaborationMode)
            }
            "thread-follower-edit-last-user-turn" => Some(Method::ThreadFollowerEditLastUserTurn),
            "thread-follower-command-approval-decision" => {
                Some(Method::ThreadFollowerCommandApprovalDecision)
            }
            "thread-follower-file-approval-decision" => {
                Some(Method::ThreadFollowerFileApprovalDecision)
            }
            "thread-follower-submit-user-input" => Some(Method::ThreadFollowerSubmitUserInput),
            "thread-follower-submit-mcp-server-elicitation-response" => {
                Some(Method::ThreadFollowerSubmitMcpServerElicitationResponse)
            }
            "thread-follower-set-queued-follow-ups-state" => {
                Some(Method::ThreadFollowerSetQueuedFollowUpsState)
            }
            "thread-queued-followups-changed" => Some(Method::ThreadQueuedFollowupsChanged),
            "query-cache-invalidate" => Some(Method::QueryCacheInvalidate),
            _ => None,
        }
    }

    /// Returns all variants, useful for exhaustive iteration in tests.
    fn all() -> &'static [Method] {
        &[
            Method::Initialize,
            Method::ClientStatusChanged,
            Method::ExternalResumeThread,
            Method::ThreadStreamStateChanged,
            Method::ThreadArchived,
            Method::ThreadUnarchived,
            Method::ThreadFollowerStartTurn,
            Method::ThreadFollowerSteerTurn,
            Method::ThreadFollowerInterruptTurn,
            Method::ThreadFollowerSetModelAndReasoning,
            Method::ThreadFollowerSetCollaborationMode,
            Method::ThreadFollowerEditLastUserTurn,
            Method::ThreadFollowerCommandApprovalDecision,
            Method::ThreadFollowerFileApprovalDecision,
            Method::ThreadFollowerSubmitUserInput,
            Method::ThreadFollowerSubmitMcpServerElicitationResponse,
            Method::ThreadFollowerSetQueuedFollowUpsState,
            Method::ThreadQueuedFollowupsChanged,
            Method::QueryCacheInvalidate,
        ]
    }
}

impl fmt::Display for Method {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.wire_name())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn roundtrip_wire_names() {
        for &m in Method::all() {
            assert_eq!(
                Method::from_wire(m.wire_name()),
                Some(m),
                "roundtrip failed for {:?} (wire: {})",
                m,
                m.wire_name(),
            );
        }
    }

    #[test]
    fn unknown_wire_name_returns_none() {
        assert_eq!(Method::from_wire("nonexistent-method"), None);
        assert_eq!(Method::from_wire(""), None);
        assert_eq!(Method::from_wire("Initialize"), None);
    }

    #[test]
    fn version_map_completeness() {
        assert_eq!(Method::Initialize.current_version(), 1);
        assert_eq!(Method::ClientStatusChanged.current_version(), 0);
        assert_eq!(Method::ExternalResumeThread.current_version(), 1);
        assert_eq!(Method::ThreadStreamStateChanged.current_version(), 5);
        assert_eq!(Method::ThreadArchived.current_version(), 2);
        assert_eq!(Method::ThreadUnarchived.current_version(), 1);
        assert_eq!(Method::ThreadFollowerStartTurn.current_version(), 1);
        assert_eq!(Method::ThreadFollowerSteerTurn.current_version(), 1);
        assert_eq!(Method::ThreadFollowerInterruptTurn.current_version(), 1);
        assert_eq!(
            Method::ThreadFollowerSetModelAndReasoning.current_version(),
            1
        );
        assert_eq!(
            Method::ThreadFollowerSetCollaborationMode.current_version(),
            1
        );
        assert_eq!(Method::ThreadFollowerEditLastUserTurn.current_version(), 1);
        assert_eq!(
            Method::ThreadFollowerCommandApprovalDecision.current_version(),
            1
        );
        assert_eq!(
            Method::ThreadFollowerFileApprovalDecision.current_version(),
            1
        );
        assert_eq!(Method::ThreadFollowerSubmitUserInput.current_version(), 1);
        assert_eq!(
            Method::ThreadFollowerSubmitMcpServerElicitationResponse.current_version(),
            1
        );
        assert_eq!(
            Method::ThreadFollowerSetQueuedFollowUpsState.current_version(),
            1
        );
        assert_eq!(Method::ThreadQueuedFollowupsChanged.current_version(), 1);
        assert_eq!(Method::QueryCacheInvalidate.current_version(), 0);
    }

    #[test]
    fn all_variants_have_unique_wire_names() {
        let mut seen = HashSet::new();
        for &m in Method::all() {
            assert!(
                seen.insert(m.wire_name()),
                "duplicate wire name: {}",
                m.wire_name(),
            );
        }
        assert_eq!(seen.len(), Method::all().len());
    }

    #[test]
    fn display_uses_wire_name() {
        for &m in Method::all() {
            assert_eq!(format!("{m}"), m.wire_name());
        }
    }
}
