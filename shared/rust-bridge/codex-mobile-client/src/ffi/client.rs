use crate::MobileClient;
use crate::ffi::ClientError;
use crate::ffi::shared::{blocking_async, shared_mobile_client, shared_runtime};
use crate::rpc::next_request_id;
use crate::types;
use codex_app_server_protocol as upstream;
use std::sync::Arc;

async fn request_server<T>(
    client: &MobileClient,
    server_id: &str,
    request: upstream::ClientRequest,
) -> Result<T, ClientError>
where
    T: serde::de::DeserializeOwned,
{
    client
        .request_typed_for_server(server_id, request)
        .await
        .map_err(|error| ClientError::Rpc(error.to_string()))
}

#[derive(uniffi::Object)]
pub struct AppClient {
    pub(crate) inner: Arc<MobileClient>,
    pub(crate) rt: Arc<tokio::runtime::Runtime>,
}

#[uniffi::export(async_runtime = "tokio")]
impl AppClient {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self {
            inner: shared_mobile_client(),
            rt: shared_runtime(),
        }
    }

    pub async fn start_thread(
        &self,
        server_id: String,
        params: types::AppStartThreadRequest,
    ) -> Result<types::ThreadKey, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let params: upstream::ThreadStartParams =
                params
                    .try_into()
                    .map_err(|error: crate::rpc::RpcClientError| {
                        ClientError::Serialization(error.to_string())
                    })?;
            let response: upstream::ThreadStartResponse = request_server(
                c.as_ref(),
                &server_id,
                upstream::ClientRequest::ThreadStart {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params,
                },
            )
            .await?;
            c.apply_thread_start_response(&server_id, &response)
                .map_err(ClientError::Serialization)
        })
    }

    pub async fn resume_thread(
        &self,
        server_id: String,
        params: types::AppResumeThreadRequest,
    ) -> Result<types::ThreadKey, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let params: upstream::ThreadResumeParams =
                params
                    .try_into()
                    .map_err(|error: crate::rpc::RpcClientError| {
                        ClientError::Serialization(error.to_string())
                    })?;
            let response: upstream::ThreadResumeResponse = request_server(
                c.as_ref(),
                &server_id,
                upstream::ClientRequest::ThreadResume {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params,
                },
            )
            .await?;
            c.apply_thread_resume_response(&server_id, &response)
                .map_err(ClientError::Serialization)
        })
    }

    pub async fn fork_thread(
        &self,
        server_id: String,
        params: types::AppForkThreadRequest,
    ) -> Result<types::ThreadKey, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let params: upstream::ThreadForkParams =
                params
                    .try_into()
                    .map_err(|error: crate::rpc::RpcClientError| {
                        ClientError::Serialization(error.to_string())
                    })?;
            let response: upstream::ThreadForkResponse = request_server(
                c.as_ref(),
                &server_id,
                upstream::ClientRequest::ThreadFork {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params,
                },
            )
            .await?;
            c.apply_thread_fork_response(&server_id, &response)
                .map_err(ClientError::Serialization)
        })
    }

    pub async fn archive_thread(
        &self,
        server_id: String,
        params: types::AppArchiveThreadRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let response: upstream::ThreadArchiveResponse = request_server(
                c.as_ref(),
                &server_id,
                upstream::ClientRequest::ThreadArchive {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params: params.into(),
                },
            )
            .await?;
            let _ = response;
            Ok(())
        })
    }

    pub async fn rename_thread(
        &self,
        server_id: String,
        params: types::AppRenameThreadRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let response: upstream::ThreadSetNameResponse = request_server(
                c.as_ref(),
                &server_id,
                upstream::ClientRequest::ThreadSetName {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params: params.into(),
                },
            )
            .await?;
            let _ = response;
            Ok(())
        })
    }

    pub async fn list_threads(
        &self,
        server_id: String,
        params: types::AppListThreadsRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let response: upstream::ThreadListResponse = request_server(
                c.as_ref(),
                &server_id,
                upstream::ClientRequest::ThreadList {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params: params.into(),
                },
            )
            .await?;
            c.sync_thread_list(&server_id, &response.data)
                .map(|_| ())
                .map_err(ClientError::Serialization)
        })
    }

    pub async fn read_thread(
        &self,
        server_id: String,
        params: types::AppReadThreadRequest,
    ) -> Result<types::ThreadKey, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let response: upstream::ThreadReadResponse = request_server(
                c.as_ref(),
                &server_id,
                upstream::ClientRequest::ThreadRead {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params: params.into(),
                },
            )
            .await?;
            c.apply_thread_read_response(&server_id, &response)
                .map_err(ClientError::Serialization)
        })
    }

    pub async fn list_skills(
        &self,
        server_id: String,
        params: types::AppListSkillsRequest,
    ) -> Result<Vec<types::SkillMetadata>, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let response: upstream::SkillsListResponse = request_server(
                c.as_ref(),
                &server_id,
                upstream::ClientRequest::SkillsList {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params: params.into(),
                },
            )
            .await?;
            Ok(response
                .data
                .into_iter()
                .flat_map(|entry| entry.skills.into_iter().map(Into::into))
                .collect())
        })
    }

    pub async fn interrupt_turn(
        &self,
        server_id: String,
        params: types::AppInterruptTurnRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let response: upstream::TurnInterruptResponse = request_server(
                c.as_ref(),
                &server_id,
                upstream::ClientRequest::TurnInterrupt {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params: params.into(),
                },
            )
            .await?;
            let _ = response;
            Ok(())
        })
    }

    pub async fn start_realtime_session(
        &self,
        server_id: String,
        params: types::AppStartRealtimeSessionRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let params: upstream::ThreadRealtimeStartParams =
                params
                    .try_into()
                    .map_err(|error: crate::rpc::RpcClientError| {
                        ClientError::Serialization(error.to_string())
                    })?;
            let response: upstream::ThreadRealtimeStartResponse = request_server(
                c.as_ref(),
                &server_id,
                upstream::ClientRequest::ThreadRealtimeStart {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params,
                },
            )
            .await?;
            let _ = response;
            Ok(())
        })
    }

    pub async fn append_realtime_audio(
        &self,
        server_id: String,
        params: types::AppAppendRealtimeAudioRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let response: upstream::ThreadRealtimeAppendAudioResponse = request_server(
                c.as_ref(),
                &server_id,
                upstream::ClientRequest::ThreadRealtimeAppendAudio {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params: params.into(),
                },
            )
            .await?;
            let _ = response;
            Ok(())
        })
    }

    pub async fn append_realtime_text(
        &self,
        server_id: String,
        params: types::AppAppendRealtimeTextRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let response: upstream::ThreadRealtimeAppendTextResponse = request_server(
                c.as_ref(),
                &server_id,
                upstream::ClientRequest::ThreadRealtimeAppendText {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params: params.into(),
                },
            )
            .await?;
            let _ = response;
            Ok(())
        })
    }

    pub async fn stop_realtime_session(
        &self,
        server_id: String,
        params: types::AppStopRealtimeSessionRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let response: upstream::ThreadRealtimeStopResponse = request_server(
                c.as_ref(),
                &server_id,
                upstream::ClientRequest::ThreadRealtimeStop {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params: params.into(),
                },
            )
            .await?;
            let _ = response;
            Ok(())
        })
    }

    pub async fn resolve_realtime_handoff(
        &self,
        server_id: String,
        params: types::AppResolveRealtimeHandoffRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let response: upstream::ThreadRealtimeResolveHandoffResponse = request_server(
                c.as_ref(),
                &server_id,
                upstream::ClientRequest::ThreadRealtimeResolveHandoff {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params: params.into(),
                },
            )
            .await?;
            let _ = response;
            Ok(())
        })
    }

    pub async fn finalize_realtime_handoff(
        &self,
        server_id: String,
        params: types::AppFinalizeRealtimeHandoffRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let response: upstream::ThreadRealtimeFinalizeHandoffResponse = request_server(
                c.as_ref(),
                &server_id,
                upstream::ClientRequest::ThreadRealtimeFinalizeHandoff {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params: params.into(),
                },
            )
            .await?;
            let _ = response;
            Ok(())
        })
    }

    pub async fn start_review(
        &self,
        server_id: String,
        params: types::AppStartReviewRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let params: upstream::ReviewStartParams =
                params
                    .try_into()
                    .map_err(|error: crate::rpc::RpcClientError| {
                        ClientError::Serialization(error.to_string())
                    })?;
            let response: upstream::ReviewStartResponse = request_server(
                c.as_ref(),
                &server_id,
                upstream::ClientRequest::ReviewStart {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params,
                },
            )
            .await?;
            let _ = response;
            Ok(())
        })
    }

    pub async fn refresh_models(
        &self,
        server_id: String,
        params: types::AppRefreshModelsRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let response: upstream::ModelListResponse = request_server(
                c.as_ref(),
                &server_id,
                upstream::ClientRequest::ModelList {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params: params.into(),
                },
            )
            .await?;
            c.apply_model_list_response(&server_id, &response);
            Ok(())
        })
    }

    pub async fn list_experimental_features(
        &self,
        server_id: String,
        params: types::AppListExperimentalFeaturesRequest,
    ) -> Result<Vec<types::ExperimentalFeature>, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let response: upstream::ExperimentalFeatureListResponse = request_server(
                c.as_ref(),
                &server_id,
                upstream::ClientRequest::ExperimentalFeatureList {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params: params.into(),
                },
            )
            .await?;
            Ok(response.data.into_iter().map(Into::into).collect())
        })
    }

    pub async fn login_account(
        &self,
        server_id: String,
        params: types::AppLoginAccountRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let response: upstream::LoginAccountResponse = request_server(
                c.as_ref(),
                &server_id,
                upstream::ClientRequest::LoginAccount {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params: params.into(),
                },
            )
            .await?;
            let _ = response;
            c.sync_server_account(&server_id)
                .await
                .map_err(|error| ClientError::Rpc(error.to_string()))
        })
    }

    pub async fn logout_account(&self, server_id: String) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.server_logout_account(&server_id).await?;
            c.sync_server_account_after_logout(&server_id)
                .await
                .map_err(|error| ClientError::Rpc(error.to_string()))
        })
    }

    pub async fn refresh_rate_limits(&self, server_id: String) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let response = c.server_get_account_rate_limits(&server_id).await?;
            c.apply_account_rate_limits_response(&server_id, &response);
            Ok(())
        })
    }

    pub async fn exec_command(
        &self,
        server_id: String,
        params: types::AppExecCommandRequest,
    ) -> Result<types::CommandExecResult, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let params: upstream::CommandExecParams =
                params
                    .try_into()
                    .map_err(|error: crate::rpc::RpcClientError| {
                        ClientError::Serialization(error.to_string())
                    })?;
            let response: upstream::CommandExecResponse = request_server(
                c.as_ref(),
                &server_id,
                upstream::ClientRequest::OneOffCommandExec {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params,
                },
            )
            .await?;
            Ok(response.into())
        })
    }

    pub async fn write_config_value(
        &self,
        server_id: String,
        params: types::AppWriteConfigValueRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let params: upstream::ConfigValueWriteParams =
                params
                    .try_into()
                    .map_err(|error: crate::rpc::RpcClientError| {
                        ClientError::Serialization(error.to_string())
                    })?;
            let response: upstream::ConfigWriteResponse = request_server(
                c.as_ref(),
                &server_id,
                upstream::ClientRequest::ConfigValueWrite {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params,
                },
            )
            .await?;
            let _ = response;
            Ok(())
        })
    }

    pub async fn refresh_account(
        &self,
        server_id: String,
        params: types::AppRefreshAccountRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let response: upstream::GetAccountResponse = request_server(
                c.as_ref(),
                &server_id,
                upstream::ClientRequest::GetAccount {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params: params.into(),
                },
            )
            .await?;
            c.apply_account_response(&server_id, &response);
            Ok(())
        })
    }

    pub async fn auth_status(
        &self,
        server_id: String,
        params: types::AuthStatusRequest,
    ) -> Result<types::AuthStatus, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let response: upstream::GetAuthStatusResponse = request_server(
                c.as_ref(),
                &server_id,
                upstream::ClientRequest::GetAuthStatus {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params: params.into(),
                },
            )
            .await?;
            Ok(response.into())
        })
    }

    pub async fn search_files(
        &self,
        server_id: String,
        params: types::AppSearchFilesRequest,
    ) -> Result<Vec<types::FileSearchResult>, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let response: upstream::FuzzyFileSearchResponse = request_server(
                c.as_ref(),
                &server_id,
                upstream::ClientRequest::FuzzyFileSearch {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params: params.into(),
                },
            )
            .await?;
            Ok(response.files.into_iter().map(Into::into).collect())
        })
    }

    pub async fn start_remote_ssh_oauth_login(
        &self,
        server_id: String,
    ) -> Result<String, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.start_remote_ssh_oauth_login(&server_id)
                .await
                .map_err(|error| ClientError::Rpc(error.to_string()))
        })
    }
}
