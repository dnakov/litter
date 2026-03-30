//! Shared model types: Thread, Turn, ThreadItem, CodexModel, Config, etc.
//!
//! These are mobile-friendly wrappers around upstream Codex protocol types.
//! They use `String` for most enum-like fields and `serde_json::Value` for
//! fields we don't fully type yet, making them resilient to server changes.
//!
//! `From` impls are provided for converting from upstream `v2::Thread` and
//! `v2::Model` types.

use codex_app_server_protocol as upstream;
use serde::{Deserialize, Serialize};

use super::enums::ThreadSummaryStatus;

/// Summary information about a thread.
///
/// This is a flattened, mobile-friendly view of the upstream `v2::Thread` type.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct ThreadInfo {
    /// Unique identifier for the thread.
    pub id: String,
    /// User-facing title, if set.
    pub title: Option<String>,
    /// The model used for this thread, if known.
    pub model: Option<String>,
    /// Current status of the thread.
    pub status: ThreadSummaryStatus,
    /// Preview text (usually the first user message).
    pub preview: Option<String>,
    /// Working directory for the thread.
    pub cwd: Option<String>,
    /// Rollout path on the server filesystem.
    pub path: Option<String>,
    /// Model provider (e.g. "openai").
    pub model_provider: Option<String>,
    /// Agent nickname for subagent threads.
    pub agent_nickname: Option<String>,
    /// Agent role for subagent threads.
    pub agent_role: Option<String>,
    /// Parent thread id for spawned/forked threads when known.
    pub parent_thread_id: Option<String>,
    /// Best-effort subagent lifecycle status string.
    pub agent_status: Option<String>,
    /// Unix timestamp (seconds) when the thread was created.
    pub created_at: Option<i64>,
    /// Unix timestamp (seconds) when the thread was last updated.
    pub updated_at: Option<i64>,
}

impl From<upstream::Thread> for ThreadInfo {
    fn from(thread: upstream::Thread) -> Self {
        // Extract agent info from source (SubAgent variant).
        let (agent_nickname, agent_role, parent_thread_id) = match &thread.source {
            upstream::SessionSource::SubAgent(sub) => {
                use codex_protocol::protocol::SubAgentSource;
                match sub {
                    SubAgentSource::ThreadSpawn {
                        parent_thread_id,
                        agent_nickname,
                        agent_role,
                        ..
                    } => (
                        agent_nickname.clone(),
                        agent_role.clone(),
                        Some(parent_thread_id.to_string()),
                    ),
                    _ => (
                        thread.agent_nickname.clone(),
                        thread.agent_role.clone(),
                        None,
                    ),
                }
            }
            _ => (
                thread.agent_nickname.clone(),
                thread.agent_role.clone(),
                None,
            ),
        };

        Self {
            id: thread.id,
            title: thread.name,
            model: None,
            status: ThreadSummaryStatus::from(thread.status),
            preview: if thread.preview.is_empty() {
                None
            } else {
                Some(thread.preview)
            },
            cwd: Some(thread.cwd.to_string_lossy().to_string()),
            path: match thread.path {
                Some(path) => Some(path.to_string_lossy().to_string()),
                None => Some(thread.cwd.to_string_lossy().to_string()),
            },
            model_provider: Some(thread.model_provider),
            agent_nickname,
            agent_role,
            parent_thread_id,
            agent_status: None,
            created_at: Some(thread.created_at),
            updated_at: Some(thread.updated_at),
        }
    }
}

impl From<codex_protocol::account::PlanType> for PlanType {
    fn from(value: codex_protocol::account::PlanType) -> Self {
        match value {
            codex_protocol::account::PlanType::Free => Self::Free,
            codex_protocol::account::PlanType::Go => Self::Go,
            codex_protocol::account::PlanType::Plus => Self::Plus,
            codex_protocol::account::PlanType::Pro => Self::Pro,
            codex_protocol::account::PlanType::Team => Self::Team,
            codex_protocol::account::PlanType::Business => Self::Business,
            codex_protocol::account::PlanType::Enterprise => Self::Enterprise,
            codex_protocol::account::PlanType::Edu => Self::Edu,
            codex_protocol::account::PlanType::Unknown => Self::Unknown,
        }
    }
}

/// Composite key identifying a thread on a specific server.
///
/// Mobile-specific — no upstream equivalent.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct ThreadKey {
    pub server_id: String,
    pub thread_id: String,
}

/// Rate limit information from the server.
///
/// Mobile-specific simplified view.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct RateLimits {
    /// Number of requests remaining in the current window.
    pub requests_remaining: Option<u64>,
    /// Number of tokens remaining in the current window.
    pub tokens_remaining: Option<u64>,
    /// ISO 8601 timestamp when the rate limit window resets.
    pub reset_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(transparent)]
#[derive(uniffi::Record)]
pub struct AbsolutePath {
    pub value: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Enum)]
pub enum JsonValueKind {
    Null,
    Bool,
    I64,
    U64,
    F64,
    String,
    Array,
    Object,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct JsonObjectEntry {
    pub key: String,
    pub value: JsonValue,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct JsonValue {
    pub kind: JsonValueKind,
    pub bool_value: Option<bool>,
    pub i64_value: Option<i64>,
    pub u64_value: Option<u64>,
    pub f64_value: Option<f64>,
    pub string_value: Option<String>,
    pub array_items: Option<Vec<JsonValue>>,
    pub object_entries: Option<Vec<JsonObjectEntry>>,
}

impl Serialize for JsonValue {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        match self.kind {
            JsonValueKind::Null => serializer.serialize_unit(),
            JsonValueKind::Bool => serializer.serialize_bool(self.bool_value.unwrap_or(false)),
            JsonValueKind::I64 => serializer.serialize_i64(self.i64_value.unwrap_or_default()),
            JsonValueKind::U64 => serializer.serialize_u64(self.u64_value.unwrap_or_default()),
            JsonValueKind::F64 => serializer.serialize_f64(self.f64_value.unwrap_or_default()),
            JsonValueKind::String => {
                serializer.serialize_str(self.string_value.as_deref().unwrap_or(""))
            }
            JsonValueKind::Array => self
                .array_items
                .clone()
                .unwrap_or_default()
                .serialize(serializer),
            JsonValueKind::Object => {
                let map: std::collections::BTreeMap<String, JsonValue> = self
                    .object_entries
                    .clone()
                    .unwrap_or_default()
                    .into_iter()
                    .map(|entry| (entry.key, entry.value))
                    .collect();
                map.serialize(serializer)
            }
        }
    }
}

impl<'de> Deserialize<'de> for JsonValue {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = serde_json::Value::deserialize(deserializer)?;
        Ok(match value {
            serde_json::Value::Null => JsonValue {
                kind: JsonValueKind::Null,
                bool_value: None,
                i64_value: None,
                u64_value: None,
                f64_value: None,
                string_value: None,
                array_items: None,
                object_entries: None,
            },
            serde_json::Value::Bool(value) => JsonValue {
                kind: JsonValueKind::Bool,
                bool_value: Some(value),
                i64_value: None,
                u64_value: None,
                f64_value: None,
                string_value: None,
                array_items: None,
                object_entries: None,
            },
            serde_json::Value::Number(value) => {
                if let Some(value) = value.as_i64() {
                    JsonValue {
                        kind: JsonValueKind::I64,
                        bool_value: None,
                        i64_value: Some(value),
                        u64_value: None,
                        f64_value: None,
                        string_value: None,
                        array_items: None,
                        object_entries: None,
                    }
                } else if let Some(value) = value.as_u64() {
                    JsonValue {
                        kind: JsonValueKind::U64,
                        bool_value: None,
                        i64_value: None,
                        u64_value: Some(value),
                        f64_value: None,
                        string_value: None,
                        array_items: None,
                        object_entries: None,
                    }
                } else {
                    JsonValue {
                        kind: JsonValueKind::F64,
                        bool_value: None,
                        i64_value: None,
                        u64_value: None,
                        f64_value: value.as_f64(),
                        string_value: None,
                        array_items: None,
                        object_entries: None,
                    }
                }
            }
            serde_json::Value::String(value) => JsonValue {
                kind: JsonValueKind::String,
                bool_value: None,
                i64_value: None,
                u64_value: None,
                f64_value: None,
                string_value: Some(value),
                array_items: None,
                object_entries: None,
            },
            serde_json::Value::Array(values) => JsonValue {
                kind: JsonValueKind::Array,
                bool_value: None,
                i64_value: None,
                u64_value: None,
                f64_value: None,
                string_value: None,
                array_items: Some(
                    values
                        .into_iter()
                        .map(serde_json::from_value)
                        .collect::<Result<Vec<JsonValue>, _>>()
                        .map_err(serde::de::Error::custom)?,
                ),
                object_entries: None,
            },
            serde_json::Value::Object(values) => JsonValue {
                kind: JsonValueKind::Object,
                bool_value: None,
                i64_value: None,
                u64_value: None,
                f64_value: None,
                string_value: None,
                array_items: None,
                object_entries: Some(
                    values
                        .into_iter()
                        .map(|(key, value)| -> Result<JsonObjectEntry, D::Error> {
                            Ok(JsonObjectEntry {
                                key,
                                value: serde_json::from_value(value)
                                    .map_err(serde::de::Error::custom)?,
                            })
                        })
                        .collect::<Result<Vec<_>, _>>()?,
                ),
            },
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct AppByteRange {
    pub start: u64,
    pub end: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct AppTextElement {
    pub byte_range: AppByteRange,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct AppDynamicToolSpec {
    pub name: String,
    pub description: String,
    pub input_schema: JsonValue,
    #[serde(default)]
    #[uniffi(default = false)]
    pub defer_loading: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
#[derive(uniffi::Enum)]
pub enum AuthMode {
    ApiKey,
    Chatgpt,
    #[serde(rename = "chatgptAuthTokens")]
    ChatgptAuthTokens,
}

impl From<upstream::AuthMode> for AuthMode {
    fn from(value: upstream::AuthMode) -> Self {
        match value {
            upstream::AuthMode::ApiKey => Self::ApiKey,
            upstream::AuthMode::Chatgpt => Self::Chatgpt,
            upstream::AuthMode::ChatgptAuthTokens => Self::ChatgptAuthTokens,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct CommandExecResult {
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
}

impl From<upstream::CommandExecResponse> for CommandExecResult {
    fn from(value: upstream::CommandExecResponse) -> Self {
        Self {
            exit_code: value.exit_code,
            stdout: value.stdout,
            stderr: value.stderr,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Enum)]
pub enum FileSearchMatchType {
    File,
    Directory,
}

impl From<upstream::FuzzyFileSearchMatchType> for FileSearchMatchType {
    fn from(value: upstream::FuzzyFileSearchMatchType) -> Self {
        match value {
            upstream::FuzzyFileSearchMatchType::File => Self::File,
            upstream::FuzzyFileSearchMatchType::Directory => Self::Directory,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
pub struct FileSearchResult {
    pub root: String,
    pub path: String,
    pub match_type: FileSearchMatchType,
    pub file_name: String,
    pub score: u32,
    #[uniffi(default = None)]
    pub indices: Option<Vec<u32>>,
}

impl From<upstream::FuzzyFileSearchResult> for FileSearchResult {
    fn from(value: upstream::FuzzyFileSearchResult) -> Self {
        Self {
            root: value.root,
            path: value.path,
            match_type: value.match_type.into(),
            file_name: value.file_name,
            score: value.score,
            indices: value.indices,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct AuthStatus {
    #[uniffi(default = None)]
    pub auth_method: Option<AuthMode>,
    #[uniffi(default = None)]
    pub auth_token: Option<String>,
    #[uniffi(default = None)]
    pub requires_openai_auth: Option<bool>,
}

impl From<upstream::GetAuthStatusResponse> for AuthStatus {
    fn from(value: upstream::GetAuthStatusResponse) -> Self {
        Self {
            auth_method: value.auth_method.map(Into::into),
            auth_token: value.auth_token,
            requires_openai_auth: value.requires_openai_auth,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "lowercase")]
#[derive(uniffi::Enum)]
pub enum PlanType {
    #[default]
    Free,
    Go,
    Plus,
    Pro,
    Team,
    Business,
    Enterprise,
    Edu,
    Unknown,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
#[derive(uniffi::Enum)]
pub enum InputModality {
    Text,
    Image,
}

impl From<codex_protocol::openai_models::InputModality> for InputModality {
    fn from(value: codex_protocol::openai_models::InputModality) -> Self {
        match value {
            codex_protocol::openai_models::InputModality::Text => Self::Text,
            codex_protocol::openai_models::InputModality::Image => Self::Image,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Enum)]
pub enum AppNetworkAccess {
    #[default]
    Restricted,
    Enabled,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Enum)]
pub enum ExperimentalFeatureStage {
    Beta,
    UnderDevelopment,
    Stable,
    Deprecated,
    Removed,
}

impl From<upstream::ExperimentalFeatureStage> for ExperimentalFeatureStage {
    fn from(value: upstream::ExperimentalFeatureStage) -> Self {
        match value {
            upstream::ExperimentalFeatureStage::Beta => Self::Beta,
            upstream::ExperimentalFeatureStage::UnderDevelopment => Self::UnderDevelopment,
            upstream::ExperimentalFeatureStage::Stable => Self::Stable,
            upstream::ExperimentalFeatureStage::Deprecated => Self::Deprecated,
            upstream::ExperimentalFeatureStage::Removed => Self::Removed,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Enum)]
pub enum AppMergeStrategy {
    Replace,
    Upsert,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "lowercase")]
#[derive(uniffi::Enum)]
pub enum ReasoningEffort {
    None,
    Minimal,
    Low,
    #[default]
    Medium,
    High,
    XHigh,
}

impl From<codex_protocol::openai_models::ReasoningEffort> for ReasoningEffort {
    fn from(value: codex_protocol::openai_models::ReasoningEffort) -> Self {
        match value {
            codex_protocol::openai_models::ReasoningEffort::None => Self::None,
            codex_protocol::openai_models::ReasoningEffort::Minimal => Self::Minimal,
            codex_protocol::openai_models::ReasoningEffort::Low => Self::Low,
            codex_protocol::openai_models::ReasoningEffort::Medium => Self::Medium,
            codex_protocol::openai_models::ReasoningEffort::High => Self::High,
            codex_protocol::openai_models::ReasoningEffort::XHigh => Self::XHigh,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "camelCase")]
#[derive(uniffi::Enum)]
pub enum AppReviewTarget {
    UncommittedChanges,
    #[serde(rename_all = "camelCase")]
    BaseBranch {
        branch: String,
    },
    #[serde(rename_all = "camelCase")]
    Commit {
        sha: String,
        title: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    Custom {
        instructions: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
#[derive(uniffi::Enum)]
pub enum ServiceTier {
    Fast,
    Flex,
}

impl From<codex_protocol::config_types::ServiceTier> for ServiceTier {
    fn from(value: codex_protocol::config_types::ServiceTier) -> Self {
        match value {
            codex_protocol::config_types::ServiceTier::Fast => Self::Fast,
            codex_protocol::config_types::ServiceTier::Flex => Self::Flex,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub struct SandboxWorkspaceWrite {
    #[serde(default)]
    pub writable_roots: Vec<AbsolutePath>,
    #[serde(default)]
    pub network_access: bool,
    #[serde(default)]
    pub exclude_tmpdir_env_var: bool,
    #[serde(default)]
    pub exclude_slash_tmp: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
#[derive(uniffi::Enum)]
pub enum AppMessagePhase {
    Commentary,
    FinalAnswer,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
#[derive(uniffi::Enum)]
pub enum SkillScope {
    User,
    Repo,
    System,
    Admin,
}

impl From<upstream::SkillScope> for SkillScope {
    fn from(value: upstream::SkillScope) -> Self {
        match value {
            upstream::SkillScope::User => Self::User,
            upstream::SkillScope::Repo => Self::Repo,
            upstream::SkillScope::System => Self::System,
            upstream::SkillScope::Admin => Self::Admin,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "kebab-case")]
#[derive(uniffi::Enum)]
pub enum AppAskForApproval {
    #[serde(rename = "untrusted")]
    UnlessTrusted,
    OnFailure,
    OnRequest,
    Granular {
        sandbox_approval: bool,
        rules: bool,
        #[serde(default)]
        skill_approval: bool,
        #[serde(default)]
        request_permissions: bool,
        mcp_elicitations: bool,
    },
    Never,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(tag = "type", rename_all = "camelCase")]
#[derive(uniffi::Enum)]
pub enum AppReadOnlyAccess {
    #[serde(rename_all = "camelCase")]
    Restricted {
        #[serde(default)]
        include_platform_defaults: bool,
        #[serde(default)]
        readable_roots: Vec<AbsolutePath>,
    },
    #[default]
    FullAccess,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "kebab-case")]
#[derive(uniffi::Enum)]
pub enum AppSandboxMode {
    ReadOnly,
    WorkspaceWrite,
    DangerFullAccess,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "camelCase")]
#[derive(uniffi::Enum)]
pub enum AppSandboxPolicy {
    DangerFullAccess,
    #[serde(rename_all = "camelCase")]
    ReadOnly {
        #[serde(default)]
        access: AppReadOnlyAccess,
        #[serde(default)]
        network_access: bool,
    },
    #[serde(rename_all = "camelCase")]
    ExternalSandbox {
        #[serde(default)]
        network_access: AppNetworkAccess,
    },
    #[serde(rename_all = "camelCase")]
    WorkspaceWrite {
        #[serde(default)]
        writable_roots: Vec<AbsolutePath>,
        #[serde(default)]
        read_only_access: AppReadOnlyAccess,
        #[serde(default)]
        network_access: bool,
        #[serde(default)]
        exclude_tmpdir_env_var: bool,
        #[serde(default)]
        exclude_slash_tmp: bool,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "camelCase")]
#[derive(uniffi::Enum)]
pub enum AppUserInput {
    Text {
        text: String,
        #[serde(default)]
        text_elements: Vec<AppTextElement>,
    },
    Image {
        url: String,
    },
    LocalImage {
        path: AbsolutePath,
    },
    Skill {
        name: String,
        path: AbsolutePath,
    },
    Mention {
        name: String,
        path: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct CreditsSnapshot {
    pub has_credits: bool,
    pub unlimited: bool,
    #[uniffi(default = None)]
    pub balance: Option<String>,
}

impl From<upstream::CreditsSnapshot> for CreditsSnapshot {
    fn from(value: upstream::CreditsSnapshot) -> Self {
        Self {
            has_credits: value.has_credits,
            unlimited: value.unlimited,
            balance: value.balance,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct RateLimitWindow {
    pub used_percent: i32,
    #[uniffi(default = None)]
    pub window_duration_mins: Option<i64>,
    #[uniffi(default = None)]
    pub resets_at: Option<i64>,
}

impl From<upstream::RateLimitWindow> for RateLimitWindow {
    fn from(value: upstream::RateLimitWindow) -> Self {
        Self {
            used_percent: value.used_percent,
            window_duration_mins: value.window_duration_mins,
            resets_at: value.resets_at,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct ReasoningEffortOption {
    pub reasoning_effort: ReasoningEffort,
    pub description: String,
}

impl From<upstream::ReasoningEffortOption> for ReasoningEffortOption {
    fn from(value: upstream::ReasoningEffortOption) -> Self {
        Self {
            reasoning_effort: value.reasoning_effort.into(),
            description: value.description,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct ModelAvailabilityNux {
    pub message: String,
}

impl From<upstream::ModelAvailabilityNux> for ModelAvailabilityNux {
    fn from(value: upstream::ModelAvailabilityNux) -> Self {
        Self {
            message: value.message,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct ModelUpgradeInfo {
    pub model: String,
    #[uniffi(default = None)]
    pub upgrade_copy: Option<String>,
    #[uniffi(default = None)]
    pub model_link: Option<String>,
    #[uniffi(default = None)]
    pub migration_markdown: Option<String>,
}

impl From<upstream::ModelUpgradeInfo> for ModelUpgradeInfo {
    fn from(value: upstream::ModelUpgradeInfo) -> Self {
        Self {
            model: value.model,
            upgrade_copy: value.upgrade_copy,
            model_link: value.model_link,
            migration_markdown: value.migration_markdown,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct SkillToolDependency {
    #[serde(rename = "type")]
    pub r#type: String,
    pub value: String,
    #[serde(default)]
    #[uniffi(default = None)]
    pub description: Option<String>,
    #[serde(default)]
    #[uniffi(default = None)]
    pub transport: Option<String>,
    #[serde(default)]
    #[uniffi(default = None)]
    pub command: Option<String>,
    #[serde(default)]
    #[uniffi(default = None)]
    pub url: Option<String>,
}

impl From<upstream::SkillToolDependency> for SkillToolDependency {
    fn from(value: upstream::SkillToolDependency) -> Self {
        Self {
            r#type: value.r#type,
            value: value.value,
            description: value.description,
            transport: value.transport,
            command: value.command,
            url: value.url,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct SkillDependencies {
    pub tools: Vec<SkillToolDependency>,
}

impl From<upstream::SkillDependencies> for SkillDependencies {
    fn from(value: upstream::SkillDependencies) -> Self {
        Self {
            tools: value.tools.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct SkillInterface {
    #[uniffi(default = None)]
    pub display_name: Option<String>,
    #[uniffi(default = None)]
    pub short_description: Option<String>,
    #[uniffi(default = None)]
    pub icon_small: Option<AbsolutePath>,
    #[uniffi(default = None)]
    pub icon_large: Option<AbsolutePath>,
    #[uniffi(default = None)]
    pub brand_color: Option<String>,
    #[uniffi(default = None)]
    pub default_prompt: Option<String>,
}

impl From<upstream::SkillInterface> for SkillInterface {
    fn from(value: upstream::SkillInterface) -> Self {
        Self {
            display_name: value.display_name,
            short_description: value.short_description,
            icon_small: value.icon_small.map(Into::into),
            icon_large: value.icon_large.map(Into::into),
            brand_color: value.brand_color,
            default_prompt: value.default_prompt,
        }
    }
}

/// Public account identity state shown in settings and server snapshots.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "camelCase")]
#[derive(uniffi::Enum)]
pub enum Account {
    #[serde(rename = "apiKey")]
    #[serde(rename_all = "camelCase")]
    ApiKey,
    #[serde(rename = "chatgpt")]
    #[serde(rename_all = "camelCase")]
    Chatgpt { email: String, plan_type: PlanType },
}

impl From<upstream::Account> for Account {
    fn from(value: upstream::Account) -> Self {
        match value {
            upstream::Account::ApiKey {} => Self::ApiKey,
            upstream::Account::Chatgpt { email, plan_type } => Self::Chatgpt {
                email,
                plan_type: plan_type.into(),
            },
        }
    }
}

/// Public experimental feature metadata returned to mobile clients.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct ExperimentalFeature {
    pub name: String,
    pub stage: ExperimentalFeatureStage,
    #[uniffi(default = None)]
    pub display_name: Option<String>,
    #[uniffi(default = None)]
    pub description: Option<String>,
    #[uniffi(default = None)]
    pub announcement: Option<String>,
    pub enabled: bool,
    pub default_enabled: bool,
}

impl From<upstream::ExperimentalFeature> for ExperimentalFeature {
    fn from(value: upstream::ExperimentalFeature) -> Self {
        Self {
            name: value.name,
            stage: value.stage.into(),
            display_name: value.display_name,
            description: value.description,
            announcement: value.announcement,
            enabled: value.enabled,
            default_enabled: value.default_enabled,
        }
    }
}

/// Public model metadata shown in mobile model pickers.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct ModelInfo {
    pub id: String,
    pub model: String,
    #[uniffi(default = None)]
    pub upgrade: Option<String>,
    #[uniffi(default = None)]
    pub upgrade_info: Option<ModelUpgradeInfo>,
    #[uniffi(default = None)]
    pub availability_nux: Option<ModelAvailabilityNux>,
    pub display_name: String,
    pub description: String,
    pub hidden: bool,
    pub supported_reasoning_efforts: Vec<ReasoningEffortOption>,
    pub default_reasoning_effort: ReasoningEffort,
    #[serde(default)]
    pub input_modalities: Vec<InputModality>,
    #[serde(default)]
    #[uniffi(default = false)]
    pub supports_personality: bool,
    pub is_default: bool,
}

impl From<upstream::Model> for ModelInfo {
    fn from(value: upstream::Model) -> Self {
        Self {
            id: value.id,
            model: value.model,
            upgrade: value.upgrade,
            upgrade_info: value.upgrade_info.map(Into::into),
            availability_nux: value.availability_nux.map(Into::into),
            display_name: value.display_name,
            description: value.description,
            hidden: value.hidden,
            supported_reasoning_efforts: value
                .supported_reasoning_efforts
                .into_iter()
                .map(Into::into)
                .collect(),
            default_reasoning_effort: value.default_reasoning_effort.into(),
            input_modalities: value.input_modalities.into_iter().map(Into::into).collect(),
            supports_personality: value.supports_personality,
            is_default: value.is_default,
        }
    }
}

/// Public account-level rate limit snapshot.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct RateLimitSnapshot {
    #[uniffi(default = None)]
    pub limit_id: Option<String>,
    #[uniffi(default = None)]
    pub limit_name: Option<String>,
    #[uniffi(default = None)]
    pub primary: Option<RateLimitWindow>,
    #[uniffi(default = None)]
    pub secondary: Option<RateLimitWindow>,
    #[uniffi(default = None)]
    pub credits: Option<CreditsSnapshot>,
    #[uniffi(default = None)]
    pub plan_type: Option<PlanType>,
}

impl From<upstream::RateLimitSnapshot> for RateLimitSnapshot {
    fn from(value: upstream::RateLimitSnapshot) -> Self {
        Self {
            limit_id: value.limit_id,
            limit_name: value.limit_name,
            primary: value.primary.map(Into::into),
            secondary: value.secondary.map(Into::into),
            credits: value.credits.map(Into::into),
            plan_type: value.plan_type.map(Into::into),
        }
    }
}

/// Public skill metadata used by mobile composer UI.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct SkillMetadata {
    pub name: String,
    pub description: String,
    #[serde(default)]
    #[uniffi(default = None)]
    pub short_description: Option<String>,
    #[serde(default)]
    #[uniffi(default = None)]
    pub interface: Option<SkillInterface>,
    #[serde(default)]
    #[uniffi(default = None)]
    pub dependencies: Option<SkillDependencies>,
    pub path: AbsolutePath,
    pub scope: SkillScope,
    pub enabled: bool,
}

impl From<upstream::SkillMetadata> for SkillMetadata {
    fn from(value: upstream::SkillMetadata) -> Self {
        Self {
            name: value.name,
            description: value.description,
            short_description: value.short_description,
            interface: value.interface.map(Into::into),
            dependencies: value.dependencies.map(Into::into),
            path: value.path.into(),
            scope: value.scope.into(),
            enabled: value.enabled,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct AppRealtimeAudioChunk {
    pub data: String,
    pub sample_rate: u32,
    pub num_channels: u32,
    #[uniffi(default = None)]
    pub samples_per_channel: Option<u32>,
    #[uniffi(default = None)]
    pub item_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct AppRealtimeClosedNotification {
    pub thread_id: String,
    #[uniffi(default = None)]
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct AppRealtimeErrorNotification {
    pub thread_id: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct AppRealtimeOutputAudioDeltaNotification {
    pub thread_id: String,
    pub audio: AppRealtimeAudioChunk,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct AppRealtimeStartedNotification {
    pub thread_id: String,
    #[uniffi(default = None)]
    pub session_id: Option<String>,
    pub version: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::enums::ThreadSummaryStatus;

    #[test]
    fn thread_info_roundtrip() {
        let info = ThreadInfo {
            id: "thr_abc123".to_string(),
            title: Some("My Thread".to_string()),
            model: Some("o4-mini".to_string()),
            status: ThreadSummaryStatus::Idle,
            preview: Some("Hello world".to_string()),
            cwd: Some("/home/user/project".to_string()),
            path: None,
            model_provider: Some("openai".to_string()),
            agent_nickname: None,
            agent_role: None,
            parent_thread_id: None,
            agent_status: None,
            created_at: Some(1700000000),
            updated_at: Some(1700001000),
        };
        let json = serde_json::to_string(&info).unwrap();
        let deserialized: ThreadInfo = serde_json::from_str(&json).unwrap();
        assert_eq!(info, deserialized);
    }

    #[test]
    fn thread_info_minimal() {
        let info = ThreadInfo {
            id: "thr_minimal".to_string(),
            title: None,
            model: None,
            status: ThreadSummaryStatus::NotLoaded,
            preview: None,
            path: None,
            model_provider: None,
            agent_nickname: None,
            agent_role: None,
            parent_thread_id: None,
            agent_status: None,
            cwd: None,
            created_at: None,
            updated_at: None,
        };
        let json = serde_json::to_value(&info).unwrap();
        assert_eq!(json["id"], "thr_minimal");
        assert!(json["title"].is_null());
    }

    #[test]
    fn thread_key_roundtrip() {
        let key = ThreadKey {
            server_id: "srv_1".to_string(),
            thread_id: "thr_abc".to_string(),
        };
        let json = serde_json::to_string(&key).unwrap();
        let deserialized: ThreadKey = serde_json::from_str(&json).unwrap();
        assert_eq!(key, deserialized);
    }

    #[test]
    fn rate_limits_roundtrip() {
        let limits = RateLimits {
            requests_remaining: Some(100),
            tokens_remaining: Some(50000),
            reset_at: Some("2026-03-20T12:00:00Z".to_string()),
        };
        let json = serde_json::to_string(&limits).unwrap();
        let deserialized: RateLimits = serde_json::from_str(&json).unwrap();
        assert_eq!(limits, deserialized);
    }

    #[test]
    fn thread_info_serializes_camel_case() {
        let info = ThreadInfo {
            id: "thr_1".to_string(),
            title: None,
            model: None,
            status: ThreadSummaryStatus::Idle,
            preview: None,
            cwd: None,
            path: None,
            model_provider: None,
            agent_nickname: None,
            agent_role: None,
            parent_thread_id: None,
            agent_status: None,
            created_at: Some(1000),
            updated_at: Some(2000),
        };
        let json = serde_json::to_value(&info).unwrap();
        assert!(json.get("createdAt").is_some());
        assert!(json.get("updatedAt").is_some());
    }

    #[test]
    fn thread_read_response_deserializes_subagent_source_and_active_status() {
        let response: upstream::ThreadReadResponse = serde_json::from_value(serde_json::json!({
            "thread": {
                "id": "thread-1",
                "preview": "hi",
                "ephemeral": false,
                "modelProvider": "openai",
                "createdAt": 1,
                "updatedAt": 2,
                "status": {
                    "type": "active",
                    "activeFlags": ["waitingOnApproval"]
                },
                "path": "/tmp/thread",
                "cwd": "/tmp/thread",
                "cliVersion": "1.0.0",
                "source": {
                    "subAgent": {
                        "thread_spawn": {
                            "parent_thread_id": "parent-1",
                            "depth": 2,
                            "agent_nickname": "Scout",
                            "agent_role": "reviewer"
                        }
                    }
                },
                "agentNickname": "Scout",
                "agentRole": "reviewer",
                "gitInfo": null,
                "name": "child",
                "turns": []
            }
        }))
        .expect("thread/read response should remain fully typed");

        match response.thread.status {
            upstream::ThreadStatus::Active { active_flags } => {
                assert_eq!(
                    active_flags,
                    vec![upstream::ThreadActiveFlag::WaitingOnApproval]
                );
            }
            other => panic!("unexpected thread status: {other:?}"),
        }

        match response.thread.source {
            upstream::SessionSource::SubAgent(
                codex_protocol::protocol::SubAgentSource::ThreadSpawn {
                    parent_thread_id,
                    depth,
                    agent_nickname,
                    agent_role,
                    ..
                },
            ) => {
                assert_eq!(parent_thread_id.to_string(), "parent-1");
                assert_eq!(depth, 2);
                assert_eq!(agent_nickname.as_deref(), Some("Scout"));
                assert_eq!(agent_role.as_deref(), Some("reviewer"));
            }
            other => panic!("unexpected session source: {other:?}"),
        }

        // Convert to upstream Thread (which has the From<Thread> for ThreadInfo impl)
        // by re-deserializing from the same JSON shape, using valid UUIDs for ThreadId fields.
        let upstream_thread: codex_app_server_protocol::Thread =
            serde_json::from_value(serde_json::json!({
                "id": "01234567-89ab-cdef-0123-456789abcdef",
                "preview": "hi",
                "ephemeral": false,
                "modelProvider": "openai",
                "createdAt": 1,
                "updatedAt": 2,
                "status": {
                    "type": "active",
                    "activeFlags": ["waitingOnApproval"]
                },
                "path": "/tmp/thread",
                "cwd": "/tmp/thread",
                "cliVersion": "1.0.0",
                "source": {
                    "subAgent": {
                        "thread_spawn": {
                            "parent_thread_id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                            "depth": 2,
                            "agent_nickname": "Scout",
                            "agent_role": "reviewer"
                        }
                    }
                },
                "agentNickname": "Scout",
                "agentRole": "reviewer",
                "gitInfo": null,
                "name": "child",
                "turns": []
            }))
            .expect("upstream Thread should deserialize");
        let info = ThreadInfo::from(upstream_thread);
        assert_eq!(
            info.parent_thread_id.as_deref(),
            Some("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        );
        assert_eq!(info.agent_nickname.as_deref(), Some("Scout"));
        assert_eq!(info.agent_role.as_deref(), Some("reviewer"));
    }

    #[test]
    fn thread_resume_response_deserializes_granular_approval_policy() {
        let response: upstream::ThreadResumeResponse = serde_json::from_value(serde_json::json!({
            "thread": {
                "id": "thread-1",
                "preview": "hi",
                "ephemeral": false,
                "modelProvider": "openai",
                "createdAt": 1,
                "updatedAt": 2,
                "status": { "type": "idle" },
                "path": "/tmp/thread",
                "cwd": "/tmp/thread",
                "cliVersion": "1.0.0",
                "source": "cli",
                "agentNickname": null,
                "agentRole": null,
                "gitInfo": null,
                "name": "thread",
                "turns": []
            },
            "model": "gpt-5",
            "modelProvider": "openai",
            "serviceTier": "fast",
            "cwd": "/tmp/thread",
            "approvalPolicy": {
                "granular": {
                    "sandbox_approval": true,
                    "rules": false,
                    "skill_approval": true,
                    "request_permissions": true,
                    "mcp_elicitations": false
                }
            },
            "approvalsReviewer": "user",
            "sandbox": {
                "type": "readOnly",
                "access": {
                    "type": "fullAccess"
                },
                "networkAccess": true
            },
            "reasoningEffort": "medium"
        }))
        .expect("thread/resume response should deserialize typed enums");

        assert_eq!(
            response.service_tier,
            Some(codex_protocol::config_types::ServiceTier::Fast)
        );
        assert_eq!(
            response.reasoning_effort,
            Some(codex_protocol::openai_models::ReasoningEffort::Medium)
        );
        match response.approval_policy {
            upstream::AskForApproval::Granular {
                sandbox_approval,
                rules,
                skill_approval,
                request_permissions,
                mcp_elicitations,
            } => {
                assert!(sandbox_approval);
                assert!(!rules);
                assert!(skill_approval);
                assert!(request_permissions);
                assert!(!mcp_elicitations);
            }
            other => panic!("unexpected approval policy: {other:?}"),
        }
    }
}
