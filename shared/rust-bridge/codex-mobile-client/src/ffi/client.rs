use crate::MobileClient;
use crate::ffi::ClientError;
use crate::ffi::shared::{blocking_async, shared_mobile_client, shared_runtime};
use crate::next_request_id;
use crate::types;
use codex_app_server_protocol as upstream;
use std::sync::Arc;

async fn rpc<T: serde::de::DeserializeOwned>(
    client: &MobileClient,
    server_id: &str,
    request: upstream::ClientRequest,
) -> Result<T, ClientError> {
    client
        .request_typed_for_server(server_id, request)
        .await
        .map_err(|error| ClientError::Rpc(error.to_string()))
}

fn convert_params<M, U>(params: M) -> Result<U, ClientError>
where
    M: TryInto<U, Error = crate::RpcClientError>,
{
    params
        .try_into()
        .map_err(|error| ClientError::Serialization(error.to_string()))
}

macro_rules! req {
    ($server_id:expr, $variant:ident, $params:expr) => {
        upstream::ClientRequest::$variant {
            request_id: upstream::RequestId::Integer(next_request_id()),
            params: $params,
        }
    };
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

    // ── Thread lifecycle ─────────────────────────────────────────────────

    pub async fn start_thread(
        &self,
        server_id: String,
        params: types::AppStartThreadRequest,
    ) -> Result<types::ThreadKey, ClientError> {
        if self.inner.has_opencode_server(&server_id) {
            return blocking_async!(self.rt, self.inner, |c| {
                c.opencode_start_thread(&server_id, params)
                    .await
                    .map_err(|error| ClientError::Rpc(error.to_string()))
            });
        }
        blocking_async!(self.rt, self.inner, |c| {
            let params = convert_params::<_, upstream::ThreadStartParams>(params)?;
            let response: upstream::ThreadStartResponse =
                rpc(c.as_ref(), &server_id, req!(server_id, ThreadStart, params)).await?;
            c.apply_thread_start_response(&server_id, &response)
                .map_err(ClientError::Serialization)
        })
    }

    pub async fn resume_thread(
        &self,
        server_id: String,
        params: types::AppResumeThreadRequest,
    ) -> Result<types::ThreadKey, ClientError> {
        if self.inner.has_opencode_server(&server_id) {
            return blocking_async!(self.rt, self.inner, |c| {
                c.opencode_resume_thread(&server_id, &params.thread_id)
                    .await
                    .map_err(|error| ClientError::Rpc(error.to_string()))
            });
        }
        blocking_async!(self.rt, self.inner, |c| {
            let params = convert_params::<_, upstream::ThreadResumeParams>(params)?;
            let response: upstream::ThreadResumeResponse = rpc(
                c.as_ref(),
                &server_id,
                req!(server_id, ThreadResume, params),
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
        if self.inner.has_opencode_server(&server_id) {
            return blocking_async!(self.rt, self.inner, |c| {
                c.opencode_fork_thread(&server_id, &params.thread_id)
                    .await
                    .map_err(|error| ClientError::Rpc(error.to_string()))
            });
        }
        blocking_async!(self.rt, self.inner, |c| {
            let params = convert_params::<_, upstream::ThreadForkParams>(params)?;
            let response: upstream::ThreadForkResponse =
                rpc(c.as_ref(), &server_id, req!(server_id, ThreadFork, params)).await?;
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
            let _: upstream::ThreadArchiveResponse = rpc(
                c.as_ref(),
                &server_id,
                req!(server_id, ThreadArchive, params.into()),
            )
            .await?;
            Ok(())
        })
    }

    pub async fn rename_thread(
        &self,
        server_id: String,
        params: types::AppRenameThreadRequest,
    ) -> Result<(), ClientError> {
        if self.inner.has_opencode_server(&server_id) {
            return blocking_async!(self.rt, self.inner, |c| {
                c.opencode_rename_thread(&server_id, params)
                    .await
                    .map_err(|error| ClientError::Rpc(error.to_string()))
            });
        }
        blocking_async!(self.rt, self.inner, |c| {
            let _: upstream::ThreadSetNameResponse = rpc(
                c.as_ref(),
                &server_id,
                req!(server_id, ThreadSetName, params.into()),
            )
            .await?;
            Ok(())
        })
    }

    pub async fn list_threads(
        &self,
        server_id: String,
        params: types::AppListThreadsRequest,
    ) -> Result<(), ClientError> {
        if self.inner.has_opencode_server(&server_id) {
            return blocking_async!(self.rt, self.inner, |c| {
                c.opencode_list_threads(&server_id, params)
                    .await
                    .map_err(|error| ClientError::Rpc(error.to_string()))
            });
        }
        blocking_async!(self.rt, self.inner, |c| {
            let params: upstream::ThreadListParams = params.into();
            let mut request_params = params.clone();
            let mut all_thread_ids = Vec::new();

            loop {
                let response: upstream::ThreadListResponse = rpc(
                    c.as_ref(),
                    &server_id,
                    req!(server_id, ThreadList, request_params.clone()),
                )
                .await?;

                let page = c.upsert_thread_list_page(&server_id, &response.data);
                all_thread_ids.extend(page.into_iter().map(|thread| thread.id));

                let Some(next_cursor) = response.next_cursor else {
                    break;
                };
                request_params.cursor = Some(next_cursor);
            }

            c.finalize_thread_list_sync(&server_id, all_thread_ids);
            Ok(())
        })
    }

    pub async fn read_thread(
        &self,
        server_id: String,
        params: types::AppReadThreadRequest,
    ) -> Result<types::ThreadKey, ClientError> {
        if self.inner.has_opencode_server(&server_id) {
            return blocking_async!(self.rt, self.inner, |c| {
                c.opencode_read_thread(&server_id, &params.thread_id, params.include_turns)
                    .await
                    .map_err(|error| ClientError::Rpc(error.to_string()))
            });
        }
        blocking_async!(self.rt, self.inner, |c| {
            let response: upstream::ThreadReadResponse = rpc(
                c.as_ref(),
                &server_id,
                req!(server_id, ThreadRead, params.into()),
            )
            .await?;
            c.apply_thread_read_response(&server_id, &response)
                .map_err(ClientError::Serialization)
        })
    }

    // ── Turn ─────────────────────────────────────────────────────────────

    pub async fn interrupt_turn(
        &self,
        server_id: String,
        params: types::AppInterruptTurnRequest,
    ) -> Result<(), ClientError> {
        if self.inner.has_opencode_server(&server_id) {
            return blocking_async!(self.rt, self.inner, |c| {
                c.opencode_interrupt_turn(&server_id, params)
                    .await
                    .map_err(|error| ClientError::Rpc(error.to_string()))
            });
        }
        blocking_async!(self.rt, self.inner, |c| {
            let _: upstream::TurnInterruptResponse = rpc(
                c.as_ref(),
                &server_id,
                req!(server_id, TurnInterrupt, params.into()),
            )
            .await?;
            Ok(())
        })
    }

    pub async fn list_collaboration_modes(
        &self,
        server_id: String,
    ) -> Result<Vec<types::AppCollaborationModePreset>, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.server_collaboration_mode_list(&server_id)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    // ── Realtime / voice ─────────────────────────────────────────────────

    pub async fn start_realtime_session(
        &self,
        server_id: String,
        params: types::AppStartRealtimeSessionRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let params = convert_params::<_, upstream::ThreadRealtimeStartParams>(params)?;
            let _: upstream::ThreadRealtimeStartResponse = rpc(
                c.as_ref(),
                &server_id,
                req!(server_id, ThreadRealtimeStart, params),
            )
            .await?;
            Ok(())
        })
    }

    pub async fn append_realtime_audio(
        &self,
        server_id: String,
        params: types::AppAppendRealtimeAudioRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let _: upstream::ThreadRealtimeAppendAudioResponse = rpc(
                c.as_ref(),
                &server_id,
                req!(server_id, ThreadRealtimeAppendAudio, params.into()),
            )
            .await?;
            Ok(())
        })
    }

    pub async fn append_realtime_text(
        &self,
        server_id: String,
        params: types::AppAppendRealtimeTextRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let _: upstream::ThreadRealtimeAppendTextResponse = rpc(
                c.as_ref(),
                &server_id,
                req!(server_id, ThreadRealtimeAppendText, params.into()),
            )
            .await?;
            Ok(())
        })
    }

    pub async fn stop_realtime_session(
        &self,
        server_id: String,
        params: types::AppStopRealtimeSessionRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let _: upstream::ThreadRealtimeStopResponse = rpc(
                c.as_ref(),
                &server_id,
                req!(server_id, ThreadRealtimeStop, params.into()),
            )
            .await?;
            Ok(())
        })
    }

    pub async fn resolve_realtime_handoff(
        &self,
        server_id: String,
        params: types::AppResolveRealtimeHandoffRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let _: upstream::ThreadRealtimeResolveHandoffResponse = rpc(
                c.as_ref(),
                &server_id,
                req!(server_id, ThreadRealtimeResolveHandoff, params.into()),
            )
            .await?;
            Ok(())
        })
    }

    pub async fn finalize_realtime_handoff(
        &self,
        server_id: String,
        params: types::AppFinalizeRealtimeHandoffRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let _: upstream::ThreadRealtimeFinalizeHandoffResponse = rpc(
                c.as_ref(),
                &server_id,
                req!(server_id, ThreadRealtimeFinalizeHandoff, params.into()),
            )
            .await?;
            Ok(())
        })
    }

    // ── Review ───────────────────────────────────────────────────────────

    pub async fn start_review(
        &self,
        server_id: String,
        params: types::AppStartReviewRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let params = convert_params::<_, upstream::ReviewStartParams>(params)?;
            let _: upstream::ReviewStartResponse =
                rpc(c.as_ref(), &server_id, req!(server_id, ReviewStart, params)).await?;
            Ok(())
        })
    }

    // ── Models & features ────────────────────────────────────────────────

    pub async fn refresh_models(
        &self,
        server_id: String,
        params: types::AppRefreshModelsRequest,
    ) -> Result<(), ClientError> {
        if self.inner.has_opencode_server(&server_id) {
            return blocking_async!(self.rt, self.inner, |c| {
                c.opencode_refresh_models(&server_id, params)
                    .await
                    .map_err(|error| ClientError::Rpc(error.to_string()))
            });
        }
        blocking_async!(self.rt, self.inner, |c| {
            let response: upstream::ModelListResponse = rpc(
                c.as_ref(),
                &server_id,
                req!(server_id, ModelList, params.into()),
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
            let response: upstream::ExperimentalFeatureListResponse = rpc(
                c.as_ref(),
                &server_id,
                req!(server_id, ExperimentalFeatureList, params.into()),
            )
            .await?;
            Ok(response.data.into_iter().map(Into::into).collect())
        })
    }

    pub async fn list_skills(
        &self,
        server_id: String,
        params: types::AppListSkillsRequest,
    ) -> Result<Vec<types::SkillMetadata>, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let response: upstream::SkillsListResponse = rpc(
                c.as_ref(),
                &server_id,
                req!(server_id, SkillsList, params.into()),
            )
            .await?;
            Ok(response
                .data
                .into_iter()
                .flat_map(|entry| entry.skills.into_iter().map(Into::into))
                .collect())
        })
    }

    // ── Account ──────────────────────────────────────────────────────────

    pub async fn login_account(
        &self,
        server_id: String,
        params: types::AppLoginAccountRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let _: upstream::LoginAccountResponse = rpc(
                c.as_ref(),
                &server_id,
                req!(server_id, LoginAccount, params.into()),
            )
            .await?;
            c.sync_server_account(&server_id)
                .await
                .map_err(|error| ClientError::Rpc(error.to_string()))
        })
    }

    pub async fn logout_account(&self, server_id: String) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let _: upstream::LogoutAccountResponse =
                rpc(c.as_ref(), &server_id, req!(server_id, LogoutAccount, None)).await?;
            c.sync_server_account_after_logout(&server_id)
                .await
                .map_err(|error| ClientError::Rpc(error.to_string()))
        })
    }

    pub async fn refresh_rate_limits(&self, server_id: String) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let response: upstream::GetAccountRateLimitsResponse = rpc(
                c.as_ref(),
                &server_id,
                req!(server_id, GetAccountRateLimits, None),
            )
            .await?;
            c.apply_account_rate_limits_response(&server_id, &response);
            Ok(())
        })
    }

    pub async fn refresh_account(
        &self,
        server_id: String,
        params: types::AppRefreshAccountRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let response: upstream::GetAccountResponse = rpc(
                c.as_ref(),
                &server_id,
                req!(server_id, GetAccount, params.into()),
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
            let response: upstream::GetAuthStatusResponse = rpc(
                c.as_ref(),
                &server_id,
                req!(server_id, GetAuthStatus, params.into()),
            )
            .await?;
            Ok(response.into())
        })
    }

    // ── Utilities ────────────────────────────────────────────────────────

    pub async fn exec_command(
        &self,
        server_id: String,
        params: types::AppExecCommandRequest,
    ) -> Result<types::CommandExecResult, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let params = convert_params::<_, upstream::CommandExecParams>(params)?;
            let response: upstream::CommandExecResponse = rpc(
                c.as_ref(),
                &server_id,
                req!(server_id, OneOffCommandExec, params),
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
            let params = convert_params::<_, upstream::ConfigValueWriteParams>(params)?;
            let _: upstream::ConfigWriteResponse = rpc(
                c.as_ref(),
                &server_id,
                req!(server_id, ConfigValueWrite, params),
            )
            .await?;
            Ok(())
        })
    }

    pub async fn search_files(
        &self,
        server_id: String,
        params: types::AppSearchFilesRequest,
    ) -> Result<Vec<types::FileSearchResult>, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let response: upstream::FuzzyFileSearchResponse = rpc(
                c.as_ref(),
                &server_id,
                req!(server_id, FuzzyFileSearch, params.into()),
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

    // ── Directory browsing ──────────────────────────────────────────────

    /// Resolve the home directory on a remote server.
    ///
    /// Tries POSIX `$HOME` first, falls back to Windows `%USERPROFILE%`.
    /// Returns `"/"` if both fail.
    pub async fn resolve_remote_home(
        &self,
        server_id: String,
    ) -> Result<String, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            // Try POSIX
            if let Ok(resp) = exec_command_simple(
                c.as_ref(),
                &server_id,
                &["/bin/sh", "-lc", r#"printf %s "$HOME""#],
                Some("/tmp"),
            )
            .await
            {
                if resp.exit_code == 0 {
                    let home = resp.stdout.trim().to_string();
                    if !home.is_empty() {
                        return Ok(home);
                    }
                }
            }
            // Fallback: Windows
            if let Ok(resp) = exec_command_simple(
                c.as_ref(),
                &server_id,
                &["cmd.exe", "/c", "echo", "%USERPROFILE%"],
                None,
            )
            .await
            {
                if resp.exit_code == 0 {
                    let home = resp.stdout.trim().to_string();
                    if !home.is_empty() && home != "%USERPROFILE%" {
                        return Ok(home);
                    }
                }
            }
            Ok("/".to_string())
        })
    }

    /// List subdirectories in a remote directory.
    ///
    /// Auto-detects Windows vs POSIX from the path format and runs the
    /// appropriate command. Returns sorted directory names.
    pub async fn list_remote_directory(
        &self,
        server_id: String,
        path: String,
    ) -> Result<types::DirectoryListResult, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let normalized = {
                let p = path.trim();
                if p.is_empty() { "/".to_string() } else { p.to_string() }
            };
            let rp = crate::remote_path::RemotePath::parse(&normalized);
            let is_windows = rp.is_windows();

            let (command, cwd): (Vec<&str>, &str) = if is_windows {
                // `dir /b /ad` in cwd — avoids path quoting issues
                (vec!["cmd.exe", "/c", "dir", "/b", "/ad"], &normalized)
            } else {
                (vec!["/bin/ls", "-1ap", &normalized], &normalized)
            };

            let resp = exec_command_simple(c.as_ref(), &server_id, &command, Some(cwd)).await?;

            if resp.exit_code != 0 {
                let msg = resp.stderr.trim();
                return Err(ClientError::Rpc(if msg.is_empty() {
                    format!("listing failed with exit code {}", resp.exit_code)
                } else {
                    msg.to_string()
                }));
            }

            let directories =
                crate::remote_path::parse_directory_listing(&resp.stdout, is_windows);
            Ok(types::DirectoryListResult {
                directories,
                path: normalized,
            })
        })
    }
}

/// Execute a simple one-shot command on a remote server.
async fn exec_command_simple(
    client: &MobileClient,
    server_id: &str,
    command: &[&str],
    cwd: Option<&str>,
) -> Result<upstream::CommandExecResponse, ClientError> {
    let params = upstream::CommandExecParams {
        command: command.iter().map(|s| s.to_string()).collect(),
        process_id: None,
        tty: false,
        stream_stdin: false,
        stream_stdout_stderr: false,
        output_bytes_cap: None,
        disable_output_cap: false,
        disable_timeout: false,
        timeout_ms: None,
        cwd: cwd.map(std::path::PathBuf::from),
        env: None,
        size: None,
        sandbox_policy: None,
    };
    rpc(
        client,
        server_id,
        req!(server_id, OneOffCommandExec, params),
    )
    .await
}
