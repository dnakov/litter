use crate::conversation;
use crate::types::AppMessagePhase;
use crate::types::{AppOperationStatus, AppSubagentStatus};

#[derive(Debug, Clone, uniffi::Record)]
pub struct HydratedConversationItem {
    pub id: String,
    pub content: HydratedConversationItemContent,
    pub source_turn_id: Option<String>,
    pub source_turn_index: Option<u32>,
    pub timestamp: Option<f64>,
    pub is_from_user_turn_boundary: bool,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum HydratedConversationItemContent {
    User(HydratedUserMessageData),
    Assistant(HydratedAssistantMessageData),
    Reasoning(HydratedReasoningData),
    TodoList(HydratedTodoListData),
    ProposedPlan(HydratedProposedPlanData),
    CommandExecution(HydratedCommandExecutionData),
    FileChange(HydratedFileChangeData),
    TurnDiff(conversation::TurnDiffData),
    McpToolCall(HydratedMcpToolCallData),
    DynamicToolCall(HydratedDynamicToolCallData),
    MultiAgentAction(HydratedMultiAgentActionData),
    WebSearch(HydratedWebSearchData),
    Widget(HydratedWidgetData),
    UserInputResponse(HydratedUserInputResponseData),
    Divider(HydratedDividerData),
    Error(HydratedErrorData),
    Note(HydratedNoteData),
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HydratedUserMessageData {
    pub text: String,
    pub image_data_uris: Vec<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HydratedAssistantMessageData {
    pub text: String,
    pub agent_nickname: Option<String>,
    pub agent_role: Option<String>,
    pub phase: Option<AppMessagePhase>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HydratedReasoningData {
    pub summary: Vec<String>,
    pub content: Vec<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HydratedTodoListData {
    pub steps: Vec<HydratedPlanStep>,
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum HydratedPlanStepStatus {
    Pending,
    InProgress,
    Completed,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HydratedPlanStep {
    pub step: String,
    pub status: HydratedPlanStepStatus,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HydratedProposedPlanData {
    pub content: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HydratedCommandExecutionData {
    pub command: String,
    pub cwd: String,
    pub status: AppOperationStatus,
    pub output: Option<String>,
    pub exit_code: Option<i32>,
    pub duration_ms: Option<i64>,
    pub process_id: Option<String>,
    pub actions: Vec<HydratedCommandActionData>,
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum HydratedCommandActionKind {
    Read,
    Search,
    ListFiles,
    Unknown,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HydratedCommandActionData {
    pub kind: HydratedCommandActionKind,
    pub command: String,
    pub name: Option<String>,
    pub path: Option<String>,
    pub query: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HydratedFileChangeData {
    pub status: AppOperationStatus,
    pub changes: Vec<conversation::FileChangeEntryData>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HydratedMcpToolCallData {
    pub server: String,
    pub tool: String,
    pub status: AppOperationStatus,
    pub duration_ms: Option<i64>,
    pub arguments_json: Option<String>,
    pub content_summary: Option<String>,
    pub structured_content_json: Option<String>,
    pub raw_output_json: Option<String>,
    pub error_message: Option<String>,
    pub progress_messages: Vec<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HydratedDynamicToolCallData {
    pub tool: String,
    pub status: AppOperationStatus,
    pub duration_ms: Option<i64>,
    pub success: Option<bool>,
    pub arguments_json: Option<String>,
    pub content_summary: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HydratedMultiAgentStateData {
    pub target_id: String,
    pub status: AppSubagentStatus,
    pub message: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HydratedMultiAgentActionData {
    pub tool: String,
    pub status: AppOperationStatus,
    pub prompt: Option<String>,
    pub targets: Vec<String>,
    pub receiver_thread_ids: Vec<String>,
    pub agent_states: Vec<HydratedMultiAgentStateData>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HydratedWebSearchData {
    pub query: String,
    pub action_json: Option<String>,
    pub is_in_progress: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HydratedWidgetData {
    pub title: String,
    pub widget_html: String,
    pub width: f64,
    pub height: f64,
    pub status: String,
    pub is_finalized: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HydratedUserInputResponseQuestionData {
    pub id: String,
    pub header: Option<String>,
    pub question: String,
    pub answer: String,
    pub options: Vec<conversation::UserInputResponseOptionData>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HydratedUserInputResponseData {
    pub questions: Vec<HydratedUserInputResponseQuestionData>,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum HydratedDividerData {
    ContextCompaction {
        is_complete: bool,
    },
    ModelRerouted {
        from_model: Option<String>,
        to_model: String,
        reason: Option<String>,
    },
    ReviewEntered {
        review: String,
    },
    ReviewExited {
        review: String,
    },
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HydratedNoteData {
    pub title: String,
    pub body: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HydratedErrorData {
    pub title: String,
    pub message: String,
    pub details: Option<String>,
}

impl From<conversation::ConversationItem> for HydratedConversationItem {
    fn from(value: conversation::ConversationItem) -> Self {
        Self {
            id: value.id,
            content: value.content.into(),
            source_turn_id: value.source_turn_id,
            source_turn_index: value.source_turn_index.map(|index| index as u32),
            timestamp: value.timestamp,
            is_from_user_turn_boundary: value.is_from_user_turn_boundary,
        }
    }
}

impl From<conversation::ConversationItemContent> for HydratedConversationItemContent {
    fn from(value: conversation::ConversationItemContent) -> Self {
        use conversation::ConversationItemContent as ItemContent;

        match value {
            ItemContent::User(data) => Self::User(HydratedUserMessageData {
                text: data.text,
                image_data_uris: data.image_data_uris,
            }),
            ItemContent::Assistant(data) => Self::Assistant(HydratedAssistantMessageData {
                text: data.text,
                agent_nickname: data.agent_nickname,
                agent_role: data.agent_role,
                phase: data.phase,
            }),
            ItemContent::Reasoning(data) => Self::Reasoning(HydratedReasoningData {
                summary: data.summary,
                content: data.content,
            }),
            ItemContent::TodoList(data) => Self::TodoList(HydratedTodoListData {
                steps: data.steps.into_iter().map(Into::into).collect(),
            }),
            ItemContent::ProposedPlan(data) => Self::ProposedPlan(HydratedProposedPlanData {
                content: data.content,
            }),
            ItemContent::CommandExecution(data) => {
                Self::CommandExecution(HydratedCommandExecutionData {
                    command: data.command,
                    cwd: data.cwd,
                    status: AppOperationStatus::from_raw(&data.status),
                    output: data.output,
                    exit_code: data.exit_code,
                    duration_ms: data.duration_ms,
                    process_id: data.process_id,
                    actions: data.actions.into_iter().map(Into::into).collect(),
                })
            }
            ItemContent::FileChange(data) => Self::FileChange(HydratedFileChangeData {
                status: AppOperationStatus::from_raw(&data.status),
                changes: data.changes.into_iter().map(Into::into).collect(),
            }),
            ItemContent::TurnDiff(data) => Self::TurnDiff(data),
            ItemContent::McpToolCall(data) => Self::McpToolCall(HydratedMcpToolCallData {
                server: data.server,
                tool: data.tool,
                status: AppOperationStatus::from_raw(&data.status),
                duration_ms: data.duration_ms,
                arguments_json: data.arguments_json,
                content_summary: data.content_summary,
                structured_content_json: data.structured_content_json,
                raw_output_json: data.raw_output_json,
                error_message: data.error_message,
                progress_messages: data.progress_messages,
            }),
            ItemContent::DynamicToolCall(data) => {
                Self::DynamicToolCall(HydratedDynamicToolCallData {
                    tool: data.tool,
                    status: AppOperationStatus::from_raw(&data.status),
                    duration_ms: data.duration_ms,
                    success: data.success,
                    arguments_json: data.arguments_json,
                    content_summary: data.content_summary,
                })
            }
            ItemContent::MultiAgentAction(data) => {
                Self::MultiAgentAction(HydratedMultiAgentActionData {
                    tool: data.tool,
                    status: AppOperationStatus::from_raw(&data.status),
                    prompt: data.prompt,
                    targets: data.targets,
                    receiver_thread_ids: data.receiver_thread_ids,
                    agent_states: data.agent_states.into_iter().map(Into::into).collect(),
                })
            }
            ItemContent::WebSearch(data) => Self::WebSearch(HydratedWebSearchData {
                query: data.query,
                action_json: data.action_json,
                is_in_progress: data.is_in_progress,
            }),
            ItemContent::Widget(data) => Self::Widget(HydratedWidgetData {
                title: data.title,
                widget_html: data.widget_html,
                width: data.width,
                height: data.height,
                status: data.status,
                is_finalized: data.is_finalized,
            }),
            ItemContent::UserInputResponse(data) => {
                Self::UserInputResponse(HydratedUserInputResponseData {
                    questions: data.questions.into_iter().map(Into::into).collect(),
                })
            }
            ItemContent::Divider(data) => Self::Divider(data.into()),
            ItemContent::Error(data) => Self::Error(HydratedErrorData {
                title: data.title,
                message: data.message,
                details: data.details,
            }),
            ItemContent::Note(data) => Self::Note(HydratedNoteData {
                title: data.title,
                body: data.body,
            }),
        }
    }
}

impl From<conversation::PlanStep> for HydratedPlanStep {
    fn from(value: conversation::PlanStep) -> Self {
        Self {
            step: value.step,
            status: match value.status.trim().to_ascii_lowercase().as_str() {
                "completed" => HydratedPlanStepStatus::Completed,
                "inprogress" | "in_progress" => HydratedPlanStepStatus::InProgress,
                _ => HydratedPlanStepStatus::Pending,
            },
        }
    }
}

impl From<conversation::CommandActionData> for HydratedCommandActionData {
    fn from(value: conversation::CommandActionData) -> Self {
        Self {
            kind: match value.kind.as_str() {
                "read" => HydratedCommandActionKind::Read,
                "search" => HydratedCommandActionKind::Search,
                "listFiles" => HydratedCommandActionKind::ListFiles,
                _ => HydratedCommandActionKind::Unknown,
            },
            command: value.command,
            name: value.name,
            path: value.path,
            query: value.query,
        }
    }
}

impl From<conversation::MultiAgentStateData> for HydratedMultiAgentStateData {
    fn from(value: conversation::MultiAgentStateData) -> Self {
        Self {
            target_id: value.target_id,
            status: AppSubagentStatus::from_raw(&value.status),
            message: value.message,
        }
    }
}

impl From<conversation::UserInputResponseQuestionData> for HydratedUserInputResponseQuestionData {
    fn from(value: conversation::UserInputResponseQuestionData) -> Self {
        Self {
            id: value.id,
            header: value.header,
            question: value.question,
            answer: value.answer,
            options: value.options.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<conversation::DividerData> for HydratedDividerData {
    fn from(value: conversation::DividerData) -> Self {
        match value {
            conversation::DividerData::ContextCompaction { is_complete } => {
                Self::ContextCompaction { is_complete }
            }
            conversation::DividerData::ModelRerouted {
                from_model,
                to_model,
                reason,
            } => Self::ModelRerouted {
                from_model,
                to_model,
                reason,
            },
            conversation::DividerData::ReviewEntered { review } => Self::ReviewEntered { review },
            conversation::DividerData::ReviewExited { review } => Self::ReviewExited { review },
        }
    }
}
