//! Auto-generated public UniFFI direct RPC surface.
//!
//! DO NOT EDIT — regenerate with: cargo run -p codex-mobile-codegen -- --ffi-rpc-out <path>

use crate::MobileClient;
use crate::ffi::ClientError;
use crate::ffi::shared::{blocking_async, shared_mobile_client, shared_runtime};
use crate::types::generated;
use std::sync::Arc;

#[derive(uniffi::Object)]
pub struct AppServerRpc {
    pub(crate) inner: Arc<MobileClient>,
    pub(crate) rt: Arc<tokio::runtime::Runtime>,
}

#[uniffi::export(async_runtime = "tokio")]
impl AppServerRpc {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self {
            inner: shared_mobile_client(),
            rt: shared_runtime(),
        }
    }

    /// Direct `thread/start` app-server RPC.
    pub async fn thread_start(
        &self,
        server_id: String,
        params: generated::ThreadStartParams,
    ) -> Result<generated::ThreadStartResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_thread_start(&server_id, params).await?;
            c.reconcile_public_rpc("thread/start", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `thread/resume` app-server RPC.
    pub async fn thread_resume(
        &self,
        server_id: String,
        params: generated::ThreadResumeParams,
    ) -> Result<generated::ThreadResumeResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_thread_resume(&server_id, params).await?;
            c.reconcile_public_rpc("thread/resume", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `thread/fork` app-server RPC.
    pub async fn thread_fork(
        &self,
        server_id: String,
        params: generated::ThreadForkParams,
    ) -> Result<generated::ThreadForkResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_thread_fork(&server_id, params).await?;
            c.reconcile_public_rpc("thread/fork", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `thread/archive` app-server RPC.
    pub async fn thread_archive(
        &self,
        server_id: String,
        params: generated::ThreadArchiveParams,
    ) -> Result<generated::ThreadArchiveResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_thread_archive(&server_id, params).await?;
            c.reconcile_public_rpc("thread/archive", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `thread/name/set` app-server RPC.
    pub async fn thread_set_name(
        &self,
        server_id: String,
        params: generated::ThreadSetNameParams,
    ) -> Result<generated::ThreadSetNameResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_thread_set_name(&server_id, params).await?;
            c.reconcile_public_rpc("thread/name/set", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `thread/rollback` app-server RPC.
    pub async fn thread_rollback(
        &self,
        server_id: String,
        params: generated::ThreadRollbackParams,
    ) -> Result<generated::ThreadRollbackResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_thread_rollback(&server_id, params).await?;
            c.reconcile_public_rpc("thread/rollback", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `thread/list` app-server RPC.
    pub async fn thread_list(
        &self,
        server_id: String,
        params: generated::ThreadListParams,
    ) -> Result<generated::ThreadListResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_thread_list(&server_id, params).await?;
            c.reconcile_public_rpc("thread/list", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `thread/read` app-server RPC.
    pub async fn thread_read(
        &self,
        server_id: String,
        params: generated::ThreadReadParams,
    ) -> Result<generated::ThreadReadResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_thread_read(&server_id, params).await?;
            c.reconcile_public_rpc("thread/read", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `skills/list` app-server RPC.
    pub async fn skills_list(
        &self,
        server_id: String,
        params: generated::SkillsListParams,
    ) -> Result<generated::SkillsListResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_skills_list(&server_id, params).await?;
            c.reconcile_public_rpc("skills/list", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `turn/start` app-server RPC.
    pub async fn turn_start(
        &self,
        server_id: String,
        params: generated::TurnStartParams,
    ) -> Result<generated::TurnStartResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_turn_start(&server_id, params).await?;
            c.reconcile_public_rpc("turn/start", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `turn/interrupt` app-server RPC.
    pub async fn turn_interrupt(
        &self,
        server_id: String,
        params: generated::TurnInterruptParams,
    ) -> Result<generated::TurnInterruptResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_turn_interrupt(&server_id, params).await?;
            c.reconcile_public_rpc("turn/interrupt", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `thread/realtime/start` app-server RPC.
    pub async fn thread_realtime_start(
        &self,
        server_id: String,
        params: generated::ThreadRealtimeStartParams,
    ) -> Result<generated::ThreadRealtimeStartResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_thread_realtime_start(&server_id, params).await?;
            c.reconcile_public_rpc("thread/realtime/start", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `thread/realtime/appendAudio` app-server RPC.
    pub async fn thread_realtime_append_audio(
        &self,
        server_id: String,
        params: generated::ThreadRealtimeAppendAudioParams,
    ) -> Result<generated::ThreadRealtimeAppendAudioResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_thread_realtime_append_audio(&server_id, params).await?;
            c.reconcile_public_rpc("thread/realtime/appendAudio", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `thread/realtime/appendText` app-server RPC.
    pub async fn thread_realtime_append_text(
        &self,
        server_id: String,
        params: generated::ThreadRealtimeAppendTextParams,
    ) -> Result<generated::ThreadRealtimeAppendTextResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_thread_realtime_append_text(&server_id, params).await?;
            c.reconcile_public_rpc("thread/realtime/appendText", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `thread/realtime/stop` app-server RPC.
    pub async fn thread_realtime_stop(
        &self,
        server_id: String,
        params: generated::ThreadRealtimeStopParams,
    ) -> Result<generated::ThreadRealtimeStopResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_thread_realtime_stop(&server_id, params).await?;
            c.reconcile_public_rpc("thread/realtime/stop", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `thread/realtime/resolveHandoff` app-server RPC.
    pub async fn thread_realtime_resolve_handoff(
        &self,
        server_id: String,
        params: generated::ThreadRealtimeResolveHandoffParams,
    ) -> Result<generated::ThreadRealtimeResolveHandoffResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_thread_realtime_resolve_handoff(&server_id, params).await?;
            c.reconcile_public_rpc("thread/realtime/resolveHandoff", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `thread/realtime/finalizeHandoff` app-server RPC.
    pub async fn thread_realtime_finalize_handoff(
        &self,
        server_id: String,
        params: generated::ThreadRealtimeFinalizeHandoffParams,
    ) -> Result<generated::ThreadRealtimeFinalizeHandoffResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_thread_realtime_finalize_handoff(&server_id, params).await?;
            c.reconcile_public_rpc("thread/realtime/finalizeHandoff", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `review/start` app-server RPC.
    pub async fn review_start(
        &self,
        server_id: String,
        params: generated::ReviewStartParams,
    ) -> Result<generated::ReviewStartResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_review_start(&server_id, params).await?;
            c.reconcile_public_rpc("review/start", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `model/list` app-server RPC.
    pub async fn model_list(
        &self,
        server_id: String,
        params: generated::ModelListParams,
    ) -> Result<generated::ModelListResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_model_list(&server_id, params).await?;
            c.reconcile_public_rpc("model/list", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `experimentalFeature/list` app-server RPC.
    pub async fn experimental_feature_list(
        &self,
        server_id: String,
        params: generated::ExperimentalFeatureListParams,
    ) -> Result<generated::ExperimentalFeatureListResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_experimental_feature_list(&server_id, params).await?;
            c.reconcile_public_rpc("experimentalFeature/list", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `account/login/start` app-server RPC.
    pub async fn login_account(
        &self,
        server_id: String,
        params: generated::LoginAccountParams,
    ) -> Result<generated::LoginAccountResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_login_account(&server_id, params).await?;
            c.reconcile_public_rpc("account/login/start", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `account/logout` app-server RPC.
    pub async fn logout_account(
        &self,
        server_id: String,
    ) -> Result<generated::LogoutAccountResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let response = c.generated_logout_account(&server_id).await?;
            c.reconcile_public_rpc("account/logout", &server_id, Option::<&()>::None, &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `account/rateLimits/read` app-server RPC.
    pub async fn get_account_rate_limits(
        &self,
        server_id: String,
    ) -> Result<generated::GetAccountRateLimitsResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let response = c.generated_get_account_rate_limits(&server_id).await?;
            c.reconcile_public_rpc("account/rateLimits/read", &server_id, Option::<&()>::None, &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `command/exec` app-server RPC.
    pub async fn one_off_command_exec(
        &self,
        server_id: String,
        params: generated::CommandExecParams,
    ) -> Result<generated::CommandExecResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_one_off_command_exec(&server_id, params).await?;
            c.reconcile_public_rpc("command/exec", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `config/value/write` app-server RPC.
    pub async fn config_value_write(
        &self,
        server_id: String,
        params: generated::ConfigValueWriteParams,
    ) -> Result<generated::ConfigWriteResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_config_value_write(&server_id, params).await?;
            c.reconcile_public_rpc("config/value/write", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `account/read` app-server RPC.
    pub async fn get_account(
        &self,
        server_id: String,
        params: generated::GetAccountParams,
    ) -> Result<generated::GetAccountResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_get_account(&server_id, params).await?;
            c.reconcile_public_rpc("account/read", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `GetAuthStatus` app-server RPC.
    pub async fn get_auth_status(
        &self,
        server_id: String,
        params: generated::GetAuthStatusParams,
    ) -> Result<generated::GetAuthStatusResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_get_auth_status(&server_id, params).await?;
            c.reconcile_public_rpc("GetAuthStatus", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }

    /// Direct `FuzzyFileSearch` app-server RPC.
    pub async fn fuzzy_file_search(
        &self,
        server_id: String,
        params: generated::FuzzyFileSearchParams,
    ) -> Result<generated::FuzzyFileSearchResponse, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let reconcile_params = params.clone();
            let response = c.generated_fuzzy_file_search(&server_id, params).await?;
            c.reconcile_public_rpc("FuzzyFileSearch", &server_id, Some(&reconcile_params), &response)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))?;
            Ok(response)
        })
    }
}
