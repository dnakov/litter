//! Auto-generated internal typed RPC helpers for MobileClient.
//!
//! DO NOT EDIT — regenerate with: cargo run -p codex-mobile-codegen -- --rpc-out <path>

use codex_app_server_protocol as upstream;
use crate::{MobileClient, types::generated};
use super::{RpcClientError, next_request_id};

pub(crate) fn convert_generated_field<T, U>(value: T) -> Result<U, RpcClientError>
where
    T: serde::Serialize,
    U: serde::de::DeserializeOwned,
{
    let value = serde_json::to_value(value)
        .map_err(|e| RpcClientError::Serialization(format!("serialize generated field value: {e}")))?;
    #[cfg(feature = "rpc-trace")]
    {
        let src = std::any::type_name::<T>();
        let dst = std::any::type_name::<U>();
        eprintln!("[codex-rpc] convert {src} -> {dst}");
    }
    serde_json::from_value(value.clone()).map_err(|e| {
        #[cfg(feature = "rpc-trace")]
        {
            let src = std::any::type_name::<T>();
            let dst = std::any::type_name::<U>();
            let json = serde_json::to_string_pretty(&value).unwrap_or_default();
            eprintln!(
                "[codex-rpc] FAILED {src} -> {dst}: {e}\n--- intermediate JSON ---\n{json}\n---"
            );
        }
        RpcClientError::Serialization(format!("deserialize upstream field value: {e}"))
    })
}

/// Auto-generated typed RPC helpers.
/// Each helper converts a generated params wrapper into the upstream request type
/// and sends it via `request_typed_for_server`.

impl TryFrom<generated::CancelLoginAccountParams> for upstream::CancelLoginAccountParams {
    type Error = RpcClientError;

    fn try_from(value: generated::CancelLoginAccountParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::CommandExecParams> for upstream::CommandExecParams {
    type Error = RpcClientError;

    fn try_from(value: generated::CommandExecParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::ConfigBatchWriteParams> for upstream::ConfigBatchWriteParams {
    type Error = RpcClientError;

    fn try_from(value: generated::ConfigBatchWriteParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::ConfigReadParams> for upstream::ConfigReadParams {
    type Error = RpcClientError;

    fn try_from(value: generated::ConfigReadParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::ConfigValueWriteParams> for upstream::ConfigValueWriteParams {
    type Error = RpcClientError;

    fn try_from(value: generated::ConfigValueWriteParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::DynamicToolSpec> for upstream::DynamicToolSpec {
    type Error = RpcClientError;

    fn try_from(value: generated::DynamicToolSpec) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::ExperimentalFeatureListParams> for upstream::ExperimentalFeatureListParams {
    type Error = RpcClientError;

    fn try_from(value: generated::ExperimentalFeatureListParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::FuzzyFileSearchParams> for upstream::FuzzyFileSearchParams {
    type Error = RpcClientError;

    fn try_from(value: generated::FuzzyFileSearchParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::GetAccountParams> for upstream::GetAccountParams {
    type Error = RpcClientError;

    fn try_from(value: generated::GetAccountParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::GetAuthStatusParams> for upstream::GetAuthStatusParams {
    type Error = RpcClientError;

    fn try_from(value: generated::GetAuthStatusParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::LoginAccountParams> for upstream::LoginAccountParams {
    type Error = RpcClientError;

    fn try_from(value: generated::LoginAccountParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::ModelListParams> for upstream::ModelListParams {
    type Error = RpcClientError;

    fn try_from(value: generated::ModelListParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::ReviewStartParams> for upstream::ReviewStartParams {
    type Error = RpcClientError;

    fn try_from(value: generated::ReviewStartParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::SkillsListParams> for upstream::SkillsListParams {
    type Error = RpcClientError;

    fn try_from(value: generated::SkillsListParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::ThreadArchiveParams> for upstream::ThreadArchiveParams {
    type Error = RpcClientError;

    fn try_from(value: generated::ThreadArchiveParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::ThreadForkParams> for upstream::ThreadForkParams {
    type Error = RpcClientError;

    fn try_from(value: generated::ThreadForkParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::ThreadListParams> for upstream::ThreadListParams {
    type Error = RpcClientError;

    fn try_from(value: generated::ThreadListParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::ThreadReadParams> for upstream::ThreadReadParams {
    type Error = RpcClientError;

    fn try_from(value: generated::ThreadReadParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::ThreadRealtimeAppendAudioParams> for upstream::ThreadRealtimeAppendAudioParams {
    type Error = RpcClientError;

    fn try_from(value: generated::ThreadRealtimeAppendAudioParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::ThreadRealtimeAppendTextParams> for upstream::ThreadRealtimeAppendTextParams {
    type Error = RpcClientError;

    fn try_from(value: generated::ThreadRealtimeAppendTextParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::ThreadRealtimeFinalizeHandoffParams> for upstream::ThreadRealtimeFinalizeHandoffParams {
    type Error = RpcClientError;

    fn try_from(value: generated::ThreadRealtimeFinalizeHandoffParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::ThreadRealtimeResolveHandoffParams> for upstream::ThreadRealtimeResolveHandoffParams {
    type Error = RpcClientError;

    fn try_from(value: generated::ThreadRealtimeResolveHandoffParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::ThreadRealtimeStartParams> for upstream::ThreadRealtimeStartParams {
    type Error = RpcClientError;

    fn try_from(value: generated::ThreadRealtimeStartParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::ThreadRealtimeStopParams> for upstream::ThreadRealtimeStopParams {
    type Error = RpcClientError;

    fn try_from(value: generated::ThreadRealtimeStopParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::ThreadResumeParams> for upstream::ThreadResumeParams {
    type Error = RpcClientError;

    fn try_from(value: generated::ThreadResumeParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::ThreadRollbackParams> for upstream::ThreadRollbackParams {
    type Error = RpcClientError;

    fn try_from(value: generated::ThreadRollbackParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::ThreadSetNameParams> for upstream::ThreadSetNameParams {
    type Error = RpcClientError;

    fn try_from(value: generated::ThreadSetNameParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::ThreadStartParams> for upstream::ThreadStartParams {
    type Error = RpcClientError;

    fn try_from(value: generated::ThreadStartParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::TurnInterruptParams> for upstream::TurnInterruptParams {
    type Error = RpcClientError;

    fn try_from(value: generated::TurnInterruptParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl TryFrom<generated::TurnStartParams> for upstream::TurnStartParams {
    type Error = RpcClientError;

    fn try_from(value: generated::TurnStartParams) -> Result<Self, Self::Error> {
        convert_generated_field(value)
    }
}

impl MobileClient {

    /// `thread/start` — auto-generated typed RPC.
    pub(crate) async fn generated_thread_start(
        &self,
        server_id: &str,
        params: generated::ThreadStartParams,
    ) -> Result<generated::ThreadStartResponse, RpcClientError> {
        let params: upstream::ThreadStartParams = params.try_into()?;
        let req = upstream::ClientRequest::ThreadStart {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `thread/resume` — auto-generated typed RPC.
    pub(crate) async fn generated_thread_resume(
        &self,
        server_id: &str,
        params: generated::ThreadResumeParams,
    ) -> Result<generated::ThreadResumeResponse, RpcClientError> {
        let params: upstream::ThreadResumeParams = params.try_into()?;
        let req = upstream::ClientRequest::ThreadResume {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `thread/fork` — auto-generated typed RPC.
    pub(crate) async fn generated_thread_fork(
        &self,
        server_id: &str,
        params: generated::ThreadForkParams,
    ) -> Result<generated::ThreadForkResponse, RpcClientError> {
        let params: upstream::ThreadForkParams = params.try_into()?;
        let req = upstream::ClientRequest::ThreadFork {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `thread/archive` — auto-generated typed RPC.
    pub(crate) async fn generated_thread_archive(
        &self,
        server_id: &str,
        params: generated::ThreadArchiveParams,
    ) -> Result<generated::ThreadArchiveResponse, RpcClientError> {
        let params: upstream::ThreadArchiveParams = params.try_into()?;
        let req = upstream::ClientRequest::ThreadArchive {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `thread/name/set` — auto-generated typed RPC.
    pub(crate) async fn generated_thread_set_name(
        &self,
        server_id: &str,
        params: generated::ThreadSetNameParams,
    ) -> Result<generated::ThreadSetNameResponse, RpcClientError> {
        let params: upstream::ThreadSetNameParams = params.try_into()?;
        let req = upstream::ClientRequest::ThreadSetName {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `thread/rollback` — auto-generated typed RPC.
    pub(crate) async fn generated_thread_rollback(
        &self,
        server_id: &str,
        params: generated::ThreadRollbackParams,
    ) -> Result<generated::ThreadRollbackResponse, RpcClientError> {
        let params: upstream::ThreadRollbackParams = params.try_into()?;
        let req = upstream::ClientRequest::ThreadRollback {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `thread/list` — auto-generated typed RPC.
    pub(crate) async fn generated_thread_list(
        &self,
        server_id: &str,
        params: generated::ThreadListParams,
    ) -> Result<generated::ThreadListResponse, RpcClientError> {
        let params: upstream::ThreadListParams = params.try_into()?;
        let req = upstream::ClientRequest::ThreadList {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `thread/read` — auto-generated typed RPC.
    pub(crate) async fn generated_thread_read(
        &self,
        server_id: &str,
        params: generated::ThreadReadParams,
    ) -> Result<generated::ThreadReadResponse, RpcClientError> {
        let params: upstream::ThreadReadParams = params.try_into()?;
        let req = upstream::ClientRequest::ThreadRead {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `skills/list` — auto-generated typed RPC.
    pub(crate) async fn generated_skills_list(
        &self,
        server_id: &str,
        params: generated::SkillsListParams,
    ) -> Result<generated::SkillsListResponse, RpcClientError> {
        let params: upstream::SkillsListParams = params.try_into()?;
        let req = upstream::ClientRequest::SkillsList {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `turn/start` — auto-generated typed RPC.
    pub(crate) async fn generated_turn_start(
        &self,
        server_id: &str,
        params: generated::TurnStartParams,
    ) -> Result<generated::TurnStartResponse, RpcClientError> {
        let params: upstream::TurnStartParams = params.try_into()?;
        let req = upstream::ClientRequest::TurnStart {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `turn/interrupt` — auto-generated typed RPC.
    pub(crate) async fn generated_turn_interrupt(
        &self,
        server_id: &str,
        params: generated::TurnInterruptParams,
    ) -> Result<generated::TurnInterruptResponse, RpcClientError> {
        let params: upstream::TurnInterruptParams = params.try_into()?;
        let req = upstream::ClientRequest::TurnInterrupt {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `thread/realtime/start` — auto-generated typed RPC.
    pub(crate) async fn generated_thread_realtime_start(
        &self,
        server_id: &str,
        params: generated::ThreadRealtimeStartParams,
    ) -> Result<generated::ThreadRealtimeStartResponse, RpcClientError> {
        let params: upstream::ThreadRealtimeStartParams = params.try_into()?;
        let req = upstream::ClientRequest::ThreadRealtimeStart {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `thread/realtime/appendAudio` — auto-generated typed RPC.
    pub(crate) async fn generated_thread_realtime_append_audio(
        &self,
        server_id: &str,
        params: generated::ThreadRealtimeAppendAudioParams,
    ) -> Result<generated::ThreadRealtimeAppendAudioResponse, RpcClientError> {
        let params: upstream::ThreadRealtimeAppendAudioParams = params.try_into()?;
        let req = upstream::ClientRequest::ThreadRealtimeAppendAudio {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `thread/realtime/appendText` — auto-generated typed RPC.
    pub(crate) async fn generated_thread_realtime_append_text(
        &self,
        server_id: &str,
        params: generated::ThreadRealtimeAppendTextParams,
    ) -> Result<generated::ThreadRealtimeAppendTextResponse, RpcClientError> {
        let params: upstream::ThreadRealtimeAppendTextParams = params.try_into()?;
        let req = upstream::ClientRequest::ThreadRealtimeAppendText {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `thread/realtime/stop` — auto-generated typed RPC.
    pub(crate) async fn generated_thread_realtime_stop(
        &self,
        server_id: &str,
        params: generated::ThreadRealtimeStopParams,
    ) -> Result<generated::ThreadRealtimeStopResponse, RpcClientError> {
        let params: upstream::ThreadRealtimeStopParams = params.try_into()?;
        let req = upstream::ClientRequest::ThreadRealtimeStop {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `thread/realtime/resolveHandoff` — auto-generated typed RPC.
    pub(crate) async fn generated_thread_realtime_resolve_handoff(
        &self,
        server_id: &str,
        params: generated::ThreadRealtimeResolveHandoffParams,
    ) -> Result<generated::ThreadRealtimeResolveHandoffResponse, RpcClientError> {
        let params: upstream::ThreadRealtimeResolveHandoffParams = params.try_into()?;
        let req = upstream::ClientRequest::ThreadRealtimeResolveHandoff {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `thread/realtime/finalizeHandoff` — auto-generated typed RPC.
    pub(crate) async fn generated_thread_realtime_finalize_handoff(
        &self,
        server_id: &str,
        params: generated::ThreadRealtimeFinalizeHandoffParams,
    ) -> Result<generated::ThreadRealtimeFinalizeHandoffResponse, RpcClientError> {
        let params: upstream::ThreadRealtimeFinalizeHandoffParams = params.try_into()?;
        let req = upstream::ClientRequest::ThreadRealtimeFinalizeHandoff {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `review/start` — auto-generated typed RPC.
    pub(crate) async fn generated_review_start(
        &self,
        server_id: &str,
        params: generated::ReviewStartParams,
    ) -> Result<generated::ReviewStartResponse, RpcClientError> {
        let params: upstream::ReviewStartParams = params.try_into()?;
        let req = upstream::ClientRequest::ReviewStart {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `model/list` — auto-generated typed RPC.
    pub(crate) async fn generated_model_list(
        &self,
        server_id: &str,
        params: generated::ModelListParams,
    ) -> Result<generated::ModelListResponse, RpcClientError> {
        let params: upstream::ModelListParams = params.try_into()?;
        let req = upstream::ClientRequest::ModelList {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `experimentalFeature/list` — auto-generated typed RPC.
    pub(crate) async fn generated_experimental_feature_list(
        &self,
        server_id: &str,
        params: generated::ExperimentalFeatureListParams,
    ) -> Result<generated::ExperimentalFeatureListResponse, RpcClientError> {
        let params: upstream::ExperimentalFeatureListParams = params.try_into()?;
        let req = upstream::ClientRequest::ExperimentalFeatureList {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `account/login/start` — auto-generated typed RPC.
    pub(crate) async fn generated_login_account(
        &self,
        server_id: &str,
        params: generated::LoginAccountParams,
    ) -> Result<generated::LoginAccountResponse, RpcClientError> {
        let params: upstream::LoginAccountParams = params.try_into()?;
        let req = upstream::ClientRequest::LoginAccount {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `account/logout` — auto-generated typed RPC.
    pub(crate) async fn generated_logout_account(
        &self,
        server_id: &str,
    ) -> Result<generated::LogoutAccountResponse, RpcClientError> {
        let req = upstream::ClientRequest::LogoutAccount {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params: None,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `account/rateLimits/read` — auto-generated typed RPC.
    pub(crate) async fn generated_get_account_rate_limits(
        &self,
        server_id: &str,
    ) -> Result<generated::GetAccountRateLimitsResponse, RpcClientError> {
        let req = upstream::ClientRequest::GetAccountRateLimits {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params: None,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `command/exec` — auto-generated typed RPC.
    pub(crate) async fn generated_one_off_command_exec(
        &self,
        server_id: &str,
        params: generated::CommandExecParams,
    ) -> Result<generated::CommandExecResponse, RpcClientError> {
        let params: upstream::CommandExecParams = params.try_into()?;
        let req = upstream::ClientRequest::OneOffCommandExec {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `config/value/write` — auto-generated typed RPC.
    pub(crate) async fn generated_config_value_write(
        &self,
        server_id: &str,
        params: generated::ConfigValueWriteParams,
    ) -> Result<generated::ConfigWriteResponse, RpcClientError> {
        let params: upstream::ConfigValueWriteParams = params.try_into()?;
        let req = upstream::ClientRequest::ConfigValueWrite {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `account/read` — auto-generated typed RPC.
    pub(crate) async fn generated_get_account(
        &self,
        server_id: &str,
        params: generated::GetAccountParams,
    ) -> Result<generated::GetAccountResponse, RpcClientError> {
        let params: upstream::GetAccountParams = params.try_into()?;
        let req = upstream::ClientRequest::GetAccount {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `GetAuthStatus` — auto-generated typed RPC.
    pub(crate) async fn generated_get_auth_status(
        &self,
        server_id: &str,
        params: generated::GetAuthStatusParams,
    ) -> Result<generated::GetAuthStatusResponse, RpcClientError> {
        let params: upstream::GetAuthStatusParams = params.try_into()?;
        let req = upstream::ClientRequest::GetAuthStatus {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }

    /// `FuzzyFileSearch` — auto-generated typed RPC.
    pub(crate) async fn generated_fuzzy_file_search(
        &self,
        server_id: &str,
        params: generated::FuzzyFileSearchParams,
    ) -> Result<generated::FuzzyFileSearchResponse, RpcClientError> {
        let params: upstream::FuzzyFileSearchParams = params.try_into()?;
        let req = upstream::ClientRequest::FuzzyFileSearch {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params,
        };
        self.request_typed_for_server(server_id, req)
            .await
            .map_err(RpcClientError::Rpc)
    }
}
