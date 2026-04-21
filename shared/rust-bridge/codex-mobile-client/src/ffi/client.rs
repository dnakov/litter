use crate::MobileClient;
use crate::ffi::ClientError;
use crate::ffi::shared::{blocking_async, shared_mobile_client, shared_runtime};
use crate::next_request_id;
use crate::types;
use base64::Engine;
use codex_app_server_protocol as upstream;
use std::sync::Arc;
use url::Url;

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

    pub async fn resolve_image_view(
        &self,
        server_id: String,
        path: String,
    ) -> Result<types::ResolvedImageViewResult, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            resolve_image_view_bytes(c.as_ref(), &server_id, &path).await
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
            let response: WireFuzzyFileSearchResponse = rpc(
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
    pub async fn resolve_remote_home(&self, server_id: String) -> Result<String, ClientError> {
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

    /// Fetch ambient suggestions for a (server_id, project_root) pair.
    ///
    /// Returns `None` if the suggestions file does not exist on the remote.
    /// Results are cached in memory for 60 seconds per (server_id, project_root).
    pub async fn ambient_suggestions(
        &self,
        server_id: String,
        project_root: String,
    ) -> Result<Option<crate::ambient_suggestions::AmbientSuggestionsSnapshot>, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            use crate::ambient_suggestions::{
                WireSnapshot, ambient_bucket, build_snapshot_from_wire, cache_insert, cache_lookup,
            };

            if let Some(cached) = cache_lookup(&c.ambient_cache, &server_id, &project_root) {
                return Ok(Some(cached));
            }

            let bucket = ambient_bucket(&project_root);
            // TODO windows: no Windows fallback in this pass
            let cmd = format!(
                "cat \"$HOME/.codex/ambient-suggestions/{bucket}/ambient-suggestions.json\" 2>/dev/null"
            );
            let resp = exec_command_simple(
                c.as_ref(),
                &server_id,
                &["/bin/sh", "-lc", &cmd],
                Some(&project_root),
            )
            .await?;

            if resp.exit_code != 0 {
                return Ok(None);
            }
            let stdout = resp.stdout.trim().to_string();
            if stdout.is_empty() {
                return Ok(None);
            }

            let wire: WireSnapshot = serde_json::from_str(&stdout).map_err(|e| {
                ClientError::Serialization(format!("ambient-suggestions parse error: {e}"))
            })?;
            let snapshot = build_snapshot_from_wire(wire)?;

            cache_insert(&c.ambient_cache, &server_id, &project_root, snapshot.clone());
            Ok(Some(snapshot))
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
                if p.is_empty() {
                    "/".to_string()
                } else {
                    p.to_string()
                }
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

            let directories = crate::remote_path::parse_directory_listing(&resp.stdout, is_windows);
            Ok(types::DirectoryListResult {
                directories,
                path: normalized,
            })
        })
    }

    /// Create a directory on a remote server. Creates intermediate parents
    /// as needed. No-op (returns Ok) if the directory already exists.
    pub async fn create_remote_directory(
        &self,
        server_id: String,
        path: String,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let normalized = path.trim().to_string();
            if normalized.is_empty() {
                return Err(ClientError::Rpc("path is empty".to_string()));
            }
            let rp = crate::remote_path::RemotePath::parse(&normalized);
            let is_windows = rp.is_windows();

            // `mkdir -p` on POSIX is idempotent. On Windows we fall back to
            // PowerShell `New-Item -Force` which mirrors that behavior and
            // handles intermediate parents.
            let command: Vec<&str> = if is_windows {
                vec![
                    "powershell",
                    "-NoProfile",
                    "-Command",
                    "New-Item",
                    "-ItemType",
                    "Directory",
                    "-Force",
                    "-Path",
                    &normalized,
                ]
            } else {
                vec!["/bin/mkdir", "-p", &normalized]
            };

            let resp = exec_command_simple(c.as_ref(), &server_id, &command, None).await?;
            if resp.exit_code != 0 {
                let msg = resp.stderr.trim();
                return Err(ClientError::Rpc(if msg.is_empty() {
                    format!("mkdir failed with exit code {}", resp.exit_code)
                } else {
                    msg.to_string()
                }));
            }
            Ok(())
        })
    }
}

/// Execute a simple one-shot command on a remote server.
pub(crate) async fn exec_command_simple(
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

/// Tolerant wire-compat mirror of `upstream::FuzzyFileSearchResponse`.
///
/// `match_type` was added upstream in March 2026 (commit 10eb3ec7f, "Simple
/// directory mentions"). Older `codex` server binaries omit it, which would
/// cause strict deserialization against `upstream::FuzzyFileSearchResponse`
/// to fail for the entire response. Default to `File` when absent.
#[derive(serde::Deserialize)]
struct WireFuzzyFileSearchResponse {
    #[serde(default)]
    files: Vec<WireFuzzyFileSearchResult>,
}

#[derive(serde::Deserialize)]
struct WireFuzzyFileSearchResult {
    root: String,
    path: String,
    #[serde(default = "default_match_type")]
    match_type: upstream::FuzzyFileSearchMatchType,
    file_name: String,
    score: u32,
    #[serde(default)]
    indices: Option<Vec<u32>>,
}

fn default_match_type() -> upstream::FuzzyFileSearchMatchType {
    upstream::FuzzyFileSearchMatchType::File
}

impl From<WireFuzzyFileSearchResult> for types::FileSearchResult {
    fn from(value: WireFuzzyFileSearchResult) -> Self {
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

async fn resolve_image_view_bytes(
    client: &MobileClient,
    server_id: &str,
    raw_path: &str,
) -> Result<types::ResolvedImageViewResult, ClientError> {
    let source = ImageViewSource::parse(raw_path)
        .ok_or_else(|| ClientError::InvalidParams("image_view path is empty".to_string()))?;

    match source {
        ImageViewSource::InlineData(bytes) => Ok(types::ResolvedImageViewResult {
            path: raw_path.to_string(),
            bytes,
        }),
        ImageViewSource::FilePath(path) => {
            if let Ok(bytes) = std::fs::read(&path) {
                return Ok(types::ResolvedImageViewResult { path, bytes });
            }

            if server_id.trim().is_empty() {
                return Err(ClientError::Rpc(
                    "Image path could not be read locally and no server is available.".to_string(),
                ));
            }

            let response =
                exec_command_simple_owned(client, server_id, image_read_command(&path), None)
                    .await?;

            if response.exit_code != 0 {
                let stderr = response.stderr.trim();
                return Err(ClientError::Rpc(if stderr.is_empty() {
                    "Image read failed.".to_string()
                } else {
                    stderr.to_string()
                }));
            }

            let payload: String = response
                .stdout
                .chars()
                .filter(|c| !c.is_whitespace())
                .collect();
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(payload)
                .map_err(|error| {
                    ClientError::Serialization(format!("invalid image base64: {error}"))
                })?;

            Ok(types::ResolvedImageViewResult { path, bytes })
        }
    }
}

async fn exec_command_simple_owned(
    client: &MobileClient,
    server_id: &str,
    command: Vec<String>,
    cwd: Option<String>,
) -> Result<upstream::CommandExecResponse, ClientError> {
    let params = upstream::CommandExecParams {
        command,
        process_id: None,
        tty: false,
        stream_stdin: false,
        stream_stdout_stderr: false,
        output_bytes_cap: Some(20_000_000),
        disable_output_cap: false,
        disable_timeout: false,
        timeout_ms: Some(15_000),
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

fn image_read_command(path: &str) -> Vec<String> {
    if is_windows_path(path) {
        return vec![
            "powershell.exe".to_string(),
            "-NoProfile".to_string(),
            "-NonInteractive".to_string(),
            "-Command".to_string(),
            "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $p = $args[0]; if ($p.StartsWith('~/') -or $p.StartsWith('~\\\\')) { $p = Join-Path $HOME $p.Substring(2) }; [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($p))".to_string(),
            path.to_string(),
        ];
    }

    vec![
        "/bin/sh".to_string(),
        "-lc".to_string(),
        r#"path="$1"; case "$path" in "~/"*) path="$HOME/${path#~/}" ;; esac; base64 < "$path""#
            .to_string(),
        "sh".to_string(),
        path.to_string(),
    ]
}

fn is_windows_path(path: &str) -> bool {
    let bytes = path.as_bytes();
    (bytes.len() >= 3
        && bytes[1] == b':'
        && bytes[0].is_ascii_alphabetic()
        && (bytes[2] == b'\\' || bytes[2] == b'/'))
        || path.starts_with("\\\\")
}

enum ImageViewSource {
    InlineData(Vec<u8>),
    FilePath(String),
}

impl ImageViewSource {
    fn parse(raw: &str) -> Option<Self> {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            return None;
        }

        if let Some(bytes) = inline_image_data(trimmed) {
            return Some(Self::InlineData(bytes));
        }

        if let Some(path) = normalized_image_path(trimmed) {
            return Some(Self::FilePath(path));
        }

        None
    }
}

fn normalized_image_path(raw: &str) -> Option<String> {
    if raw.starts_with("file://") {
        let url = Url::parse(raw).ok()?;
        if url.scheme() == "file" {
            return url
                .to_file_path()
                .ok()
                .map(|path| path.to_string_lossy().into_owned());
        }
    }

    if raw.starts_with('/')
        || raw.starts_with("~/")
        || raw.starts_with("\\\\")
        || is_windows_path(raw)
    {
        return Some(raw.to_string());
    }

    None
}

fn inline_image_data(raw: &str) -> Option<Vec<u8>> {
    let source = raw.strip_prefix("data:image/")?;
    let (_, payload) = source.split_once(";base64,")?;
    let normalized: String = payload.chars().filter(|c| !c.is_whitespace()).collect();
    base64::engine::general_purpose::STANDARD
        .decode(normalized)
        .ok()
}

#[cfg(test)]
mod tests {
    use super::{ImageViewSource, image_read_command, normalized_image_path};

    #[test]
    fn parses_inline_image_data() {
        let source = ImageViewSource::parse("data:image/png;base64,SGVsbG8=");
        match source {
            Some(ImageViewSource::InlineData(bytes)) => assert_eq!(bytes, b"Hello"),
            _ => panic!("expected inline image data"),
        }
    }

    #[test]
    fn normalizes_file_url_path() {
        assert_eq!(
            normalized_image_path("file:///tmp/example.png").as_deref(),
            Some("/tmp/example.png")
        );
    }

    #[test]
    fn builds_posix_image_read_command_with_remote_tilde_expansion() {
        let command = image_read_command("~/image.png");
        assert_eq!(command[0], "/bin/sh");
        assert!(command[2].contains(r#"${path#~/}"#));
    }
}
