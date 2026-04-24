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
            // New thread: no `thread_id` yet, so no saved apps to
            // reference. `saved_apps_context_for_thread` returns None
            // for an unknown thread; `splice_saved_apps_context` is a
            // no-op in that case, preserving existing behavior.
            let mut params = params;
            params.developer_instructions =
                splice_saved_apps_context(c.as_ref(), None, params.developer_instructions);
            params.developer_instructions =
                splice_generative_ui_preamble(&params.dynamic_tools, params.developer_instructions);
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
            // Prepend "Apps saved in this thread so far: …" to the
            // developer_instructions so the model knows which slugs are
            // already in use.
            let mut params = params;
            let thread_id = params.thread_id.clone();
            params.developer_instructions = splice_saved_apps_context(
                c.as_ref(),
                Some(thread_id.as_str()),
                params.developer_instructions,
            );
            // Resume requests don't carry `dynamic_tools` (the server
            // remembers them from start). The preamble was injected at
            // start_thread; developer_instructions persist server-side
            // across turns, so no re-injection needed here.
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

    /// Register the directory where `saved_apps.rs` persists the app
    /// index + per-app files. Platforms (iOS/Android) call this once at
    /// process start with the same path they pass to `saved_apps_list`.
    /// When set, the `show_widget` auto-upsert hook in the dynamic-tool
    /// handler uses this directory to persist finalized widgets.
    pub fn set_saved_apps_directory(&self, directory: String) {
        let mut guard = self
            .inner
            .saved_apps_directory
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        *guard = if directory.is_empty() {
            None
        } else {
            Some(directory)
        };
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

            cache_insert(
                &c.ambient_cache,
                &server_id,
                &project_root,
                snapshot.clone(),
            );
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

    // ── Local codex (direct-dist Mac) ────────────────────────────────────

    /// Attach to an existing `codex app-server` on `127.0.0.1:{port}`, or
    /// spawn one using the bundled binary resolver. The returned record
    /// carries enough data to drive `connect_remote_server` on the Swift
    /// side; if `handle` is present the caller must hold it (and call
    /// `stop()` on app termination) to keep the child alive.
    pub async fn attach_or_spawn_local_server(
        &self,
        port: u16,
        codex_home: Option<String>,
    ) -> Result<LocalServerConnection, ClientError> {
        let rt = Arc::clone(&self.rt);
        let codex_home = codex_home.map(std::path::PathBuf::from);
        let attach = rt
            .spawn(async move {
                crate::local_server::attach_or_spawn_local_server(port, codex_home).await
            })
            .await
            .map_err(|err| ClientError::Rpc(format!("task join error: {err}")))?
            .map_err(|err| ClientError::Transport(err.to_string()))?;

        let codex_path = attach
            .codex_path
            .as_ref()
            .map(|p| p.to_string_lossy().into_owned());
        let handle = attach
            .handle
            .map(|h| Arc::new(LocalServerProcessHandle::new(h)));

        Ok(LocalServerConnection {
            host: "127.0.0.1".to_string(),
            port: attach.port,
            websocket_url: format!("ws://127.0.0.1:{}", attach.port),
            attached_to_existing: attach.attached_to_existing,
            codex_path,
            handle,
        })
    }

    // ── Saved apps update ────────────────────────────────────────────────

    /// Spin a short-lived hidden thread on `server_id`, seed it with the
    /// saved app's current HTML + abbreviated state shape, send
    /// `user_prompt`, and wait for the first finalized `show_widget`
    /// call. On success, replace the saved app's HTML on disk. On
    /// failure or cancellation, the saved app is left untouched. The
    /// hidden thread is cleaned up either way (archived on the server;
    /// also removed from the local hidden-threads list).
    pub async fn update_saved_app(
        &self,
        server_id: String,
        directory: String,
        app_id: String,
        user_prompt: String,
    ) -> SavedAppUpdateResult {
        let inner = Arc::clone(&self.inner);
        let rt = Arc::clone(&self.rt);
        let task = rt.spawn_blocking(move || {
            let inner = Arc::clone(&inner);
            let rt_for_block = Arc::clone(&crate::ffi::shared::shared_runtime());
            rt_for_block.block_on(async move {
                perform_update_saved_app(inner.as_ref(), server_id, directory, app_id, user_prompt)
                    .await
            })
        });
        match task.await {
            Ok(result) => result,
            Err(error) => SavedAppUpdateResult::Error {
                message: format!("update_saved_app task join failed: {error}"),
            },
        }
    }

    // ── Minigame ─────────────────────────────────────────────────────────

    /// Spin an ephemeral thread, generate a minigame via `show_widget`,
    /// persist it under `parent_thread_id`, and return the result.
    /// Times out after 30 seconds. Errors are returned as
    /// `ClientError::MinigameGenerationFailed`.
    pub async fn start_minigame(
        &self,
        request: AppMinigameRequest,
    ) -> Result<AppMinigameResult, crate::ffi::ClientError> {
        let inner = Arc::clone(&self.inner);
        let mg_request = crate::mobile_client::minigame::MinigameRequest {
            server_id: request.server_id,
            parent_thread_id: request.parent_thread_id,
            last_user_message: request.last_user_message,
            last_assistant_message: request.last_assistant_message,
        };
        crate::mobile_client::minigame::run_minigame(inner.as_ref(), mg_request)
            .await
            .map(|result| AppMinigameResult {
                ephemeral_thread_id: result.ephemeral_thread_id,
                widget_html: result.widget_html,
                title: result.title,
                width: result.width,
                height: result.height,
            })
            .map_err(crate::ffi::ClientError::MinigameGenerationFailed)
    }

    // ── Structured response (for app-mode `window.structuredResponse`) ───

    /// One-shot schema-constrained query against an ephemeral hidden
    /// thread. `cached_thread_id` is `None` on the first call from a saved
    /// app view; the helper starts an ephemeral thread, sends the turn with
    /// `output_schema` set, waits for the final assistant message, and
    /// returns the (JSON-string) response plus the resolved thread id so
    /// the host can cache it for subsequent calls in the same view.
    ///
    /// On a stale cached thread id (server reconnect, ephemeral thread
    /// gone), the helper transparently creates a fresh ephemeral thread
    /// and retries once. The caller should always overwrite its cache
    /// with the returned `thread_id`.
    pub async fn structured_response(
        &self,
        server_id: String,
        cached_thread_id: Option<String>,
        prompt: String,
        output_schema_json: String,
    ) -> StructuredResponseResult {
        let inner = Arc::clone(&self.inner);
        let rt = Arc::clone(&self.rt);
        let task = rt.spawn_blocking(move || {
            let inner = Arc::clone(&inner);
            let rt_for_block = Arc::clone(&crate::ffi::shared::shared_runtime());
            rt_for_block.block_on(async move {
                perform_structured_response(
                    inner.as_ref(),
                    server_id,
                    cached_thread_id,
                    prompt,
                    output_schema_json,
                )
                .await
            })
        });
        match task.await {
            Ok(result) => result,
            Err(error) => StructuredResponseResult::Error {
                message: format!("structured_response task join failed: {error}"),
            },
        }
    }

    // ── iPhone ↔ Mac proximity pairing ───────────────────────────────────

    /// Start the Mac-side pair host: bind a TCP listener, accept inbound
    /// pair WebSocket connections, and stage NI discovery tokens. Returns
    /// the bound port + Bonjour TXT entries so Swift can publish a
    /// `_litter-pair._tcp.` NetService alongside the Feature A local
    /// codex.
    ///
    /// `device_name` is the Mac's user-facing name (used as Bonjour
    /// instance name suggestion). `mac_id` is a stable per-Mac UUID
    /// (Swift persists this in UserDefaults — random UUID on first call).
    pub async fn start_pair_host(
        &self,
        device_name: String,
        mac_id: String,
        codex_port: u16,
    ) -> Result<PairHostStartResult, ClientError> {
        let rt = Arc::clone(&self.rt);
        let result = rt
            .spawn(
                async move { crate::pair::start_pair_host(device_name, mac_id, codex_port).await },
            )
            .await
            .map_err(|err| ClientError::Rpc(format!("task join error: {err}")))?
            .map_err(|err| ClientError::Transport(err.to_string()))?;
        let (handle, info) = result;
        Ok(PairHostStartResult { handle, info })
    }

    /// Open a WebSocket pair connection from the iPhone to the Mac's
    /// pair host. Sends the iPhone's hello inline; subsequent state is
    /// surfaced via the returned handle's `poll_event`.
    pub async fn pair_from_iphone(
        &self,
        host: String,
        port: u16,
        device_name: String,
        ni_discovery_token_b64: String,
    ) -> Result<Arc<crate::pair::PairClientHandle>, ClientError> {
        let rt = Arc::clone(&self.rt);
        rt.spawn(async move {
            crate::pair::pair_from_iphone(host, port, device_name, ni_discovery_token_b64).await
        })
        .await
        .map_err(|err| ClientError::Rpc(format!("task join error: {err}")))?
        .map_err(|err| ClientError::Transport(err.to_string()))
    }
}

/// Result of `AppClient::start_pair_host` — bundles the host handle (used
/// by Swift to drive the state machine) with the Bonjour publish info
/// (used by Swift to advertise a NetService).
#[derive(uniffi::Record)]
pub struct PairHostStartResult {
    pub handle: Arc<crate::pair::PairHostHandle>,
    pub info: crate::pair::PairServiceInfo,
}

/// Owning wrapper around a spawned `codex app-server` process. Exposed
/// to Swift/Kotlin as a UniFFI Object so the platform can hold it for the
/// lifetime of the app and call `stop()` on termination.
#[derive(uniffi::Object)]
pub struct LocalServerProcessHandle {
    inner: tokio::sync::Mutex<Option<crate::local_server::LocalServerHandle>>,
}

impl LocalServerProcessHandle {
    fn new(handle: crate::local_server::LocalServerHandle) -> Self {
        Self {
            inner: tokio::sync::Mutex::new(Some(handle)),
        }
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl LocalServerProcessHandle {
    /// Gracefully stop the spawned codex process. No-op if already stopped
    /// or if the handle represents an attached (not spawned) connection.
    pub async fn stop(&self) {
        let maybe = {
            let mut guard = self.inner.lock().await;
            guard.take()
        };
        if let Some(handle) = maybe {
            handle.stop().await;
        }
    }
}

/// Result of `AppClient::attach_or_spawn_local_server`.
#[derive(uniffi::Record)]
pub struct LocalServerConnection {
    /// Always `127.0.0.1` for a local codex. Included for symmetry with
    /// `connect_remote_server` on the Swift side.
    pub host: String,
    pub port: u16,
    pub websocket_url: String,
    /// `true` when we found an existing listener and did not spawn; in
    /// that case `handle` is `None`.
    pub attached_to_existing: bool,
    /// Resolved path to the `codex` binary when we spawned; `None` when
    /// we attached to an existing listener.
    pub codex_path: Option<String>,
    /// Lifetime handle for the spawned child. `None` when we attached.
    /// The caller must hold this (e.g. in the AppDelegate) and invoke
    /// `stop()` during `applicationWillTerminate`.
    pub handle: Option<Arc<LocalServerProcessHandle>>,
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
        permission_profile: None,
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
        permission_profile: None,
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

/// Return the "Apps saved in this thread so far: …" context line for
/// the given `thread_id`, or `None` when:
/// - `thread_id` is `None` (no thread yet, nothing to reference),
/// - the saved-apps directory hasn't been registered by the platform,
/// - the directory has no apps for this thread.
fn saved_apps_context_line(client: &MobileClient, thread_id: Option<&str>) -> Option<String> {
    let thread_id = thread_id?;
    let directory = {
        let guard = client
            .saved_apps_directory
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        guard.clone()?
    };
    let apps = crate::saved_apps::saved_apps_for_thread(directory, thread_id.to_string());
    if apps.is_empty() {
        return None;
    }
    let joined = apps
        .iter()
        .map(|app| format!("{} ({})", app.app_id, app.title))
        .collect::<Vec<_>>()
        .join(", ");
    Some(format!("Apps saved in this thread so far: {joined}"))
}

/// Prepend the saved-apps context line to `existing` if the thread has
/// any saved apps. If there are no apps (or no thread yet), returns
/// `existing` unchanged so callers can feed this directly into the RPC
/// request params.
fn splice_saved_apps_context(
    client: &MobileClient,
    thread_id: Option<&str>,
    existing: Option<String>,
) -> Option<String> {
    let Some(line) = saved_apps_context_line(client, thread_id) else {
        return existing;
    };
    Some(match existing {
        Some(prev) if !prev.trim().is_empty() => format!("{line}\n\n{prev}"),
        _ => line,
    })
}

/// Prepend the generative-UI preamble when this thread is registering the
/// `show_widget` / `visualize_read_me` dynamic tools (i.e., a local-server
/// thread per the I3/A3 gating rule). Platforms decide whether to pass
/// these tools in; Rust just checks the request and conditionally injects
/// the nudge.
fn splice_generative_ui_preamble(
    dynamic_tools: &Option<Vec<crate::types::models::AppDynamicToolSpec>>,
    existing: Option<String>,
) -> Option<String> {
    let has_show_widget = dynamic_tools
        .as_ref()
        .map(|tools| tools.iter().any(|t| t.name == "show_widget"))
        .unwrap_or(false);
    if !has_show_widget {
        return existing;
    }
    let preamble = crate::widget_guidelines::GENERATIVE_UI_PREAMBLE;
    Some(match existing {
        Some(prev) if !prev.trim().is_empty() => format!("{preamble}\n\n{prev}"),
        _ => preamble.to_string(),
    })
}

// ── Saved apps update helpers ────────────────────────────────────────────

/// Typed result of `AppClient::update_saved_app`.
#[derive(uniffi::Enum)]
pub enum SavedAppUpdateResult {
    Success { app: crate::saved_apps::SavedApp },
    Error { message: String },
}

/// Typed result of `AppClient::structured_response`.
#[derive(uniffi::Enum)]
pub enum StructuredResponseResult {
    Success {
        /// The ephemeral thread id the call landed on. The caller MUST
        /// overwrite its cache from this value on every success — on
        /// stale-thread recovery this differs from the `cached_thread_id`
        /// passed in.
        thread_id: String,
        /// Raw JSON string matching the caller's `output_schema`. The
        /// caller is expected to `JSON.parse` it.
        response_json: String,
    },
    Error {
        message: String,
    },
}

// ── Minigame types ───────────────────────────────────────────────────────

/// Request to `AppClient::start_minigame`.
#[derive(uniffi::Record)]
pub struct AppMinigameRequest {
    pub server_id: String,
    pub parent_thread_id: String,
    pub last_user_message: Option<String>,
    pub last_assistant_message: Option<String>,
}

/// Successful result of `AppClient::start_minigame`.
#[derive(uniffi::Record)]
pub struct AppMinigameResult {
    pub ephemeral_thread_id: String,
    pub widget_html: String,
    pub title: String,
    pub width: f64,
    pub height: f64,
}

const STRUCTURED_RESPONSE_TIMEOUT_SECS: u64 = 60;

const SAVED_APP_UPDATE_TIMEOUT_SECS: u64 = 120;

fn is_stale_thread_error(err: &str) -> bool {
    let lower = err.to_ascii_lowercase();
    lower.contains("thread not found")
        || lower.contains("conversation not found")
        || lower.contains("unknown thread")
        || lower.contains("no such thread")
}

async fn start_ephemeral_thread_for_structured(
    client: &crate::MobileClient,
    server_id: &str,
) -> Result<String, String> {
    let start_params = upstream::ThreadStartParams {
        model: None,
        model_provider: None,
        service_tier: None,
        cwd: None,
        approval_policy: None,
        approvals_reviewer: None,
        sandbox: None,
        permission_profile: None,
        config: None,
        service_name: None,
        base_instructions: None,
        developer_instructions: None,
        personality: None,
        ephemeral: Some(true),
        session_start_source: None,
        dynamic_tools: None,
        mock_experimental_field: None,
        experimental_raw_events: false,
        persist_extended_history: false,
    };
    let response: upstream::ThreadStartResponse = client
        .request_typed_for_server(
            server_id,
            upstream::ClientRequest::ThreadStart {
                request_id: upstream::RequestId::Integer(next_request_id()),
                params: start_params,
            },
        )
        .await
        .map_err(|e| format!("thread/start failed: {e}"))?;
    Ok(response.thread.id)
}

async fn run_structured_turn(
    client: &crate::MobileClient,
    server_id: &str,
    thread_id: &str,
    prompt: &str,
    output_schema: serde_json::Value,
) -> Result<String, StructuredTurnError> {
    // Subscribe BEFORE sending the turn so we don't miss a very fast
    // completion. `UiEvent` is the typed, thread-scoped event stream the
    // mobile client already fans out to the store.
    let mut events_rx = client.event_processor.subscribe();

    let turn_params = upstream::TurnStartParams {
        thread_id: thread_id.to_string(),
        input: vec![upstream::UserInput::Text {
            text: prompt.to_string(),
            text_elements: Vec::new(),
        }],
        responsesapi_client_metadata: None,
        cwd: None,
        approval_policy: None,
        approvals_reviewer: None,
        sandbox_policy: None,
        environments: None,
        permission_profile: None,
        model: None,
        service_tier: None,
        effort: None,
        summary: None,
        personality: None,
        output_schema: Some(output_schema),
        collaboration_mode: None,
    };
    let turn_outcome: Result<upstream::TurnStartResponse, _> = client
        .request_typed_for_server(
            server_id,
            upstream::ClientRequest::TurnStart {
                request_id: upstream::RequestId::Integer(next_request_id()),
                params: turn_params,
            },
        )
        .await;
    if let Err(e) = turn_outcome {
        if is_stale_thread_error(&e) {
            return Err(StructuredTurnError::StaleThread);
        }
        return Err(StructuredTurnError::Fatal(format!(
            "turn/start failed: {e}"
        )));
    }

    let wait_outcome = tokio::time::timeout(
        std::time::Duration::from_secs(STRUCTURED_RESPONSE_TIMEOUT_SECS),
        async {
            let mut last_agent_text: Option<String> = None;
            loop {
                match events_rx.recv().await {
                    Ok(crate::session::events::UiEvent::ItemCompleted { notification, .. })
                        if notification.thread_id == thread_id =>
                    {
                        if let upstream::ThreadItem::AgentMessage { text, .. } = &notification.item
                        {
                            last_agent_text = Some(text.clone());
                        }
                    }
                    Ok(crate::session::events::UiEvent::TurnCompleted { key, error, .. })
                        if key.thread_id == thread_id && key.server_id == server_id =>
                    {
                        return Ok((last_agent_text, error));
                    }
                    Ok(_) => continue,
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                        return Err("event stream closed".to_string());
                    }
                }
            }
        },
    )
    .await;

    match wait_outcome {
        Ok(Ok((_, Some(err)))) => Err(StructuredTurnError::Fatal(err)),
        Ok(Ok((Some(text), None))) => Ok(text),
        Ok(Ok((None, None))) => Err(StructuredTurnError::Fatal(
            "turn completed with no assistant message".to_string(),
        )),
        Ok(Err(msg)) => Err(StructuredTurnError::Fatal(msg)),
        Err(_) => Err(StructuredTurnError::Fatal(format!(
            "timed out after {STRUCTURED_RESPONSE_TIMEOUT_SECS}s waiting for structured response"
        ))),
    }
}

enum StructuredTurnError {
    StaleThread,
    Fatal(String),
}

async fn perform_structured_response(
    client: &crate::MobileClient,
    server_id: String,
    cached_thread_id: Option<String>,
    prompt: String,
    output_schema_json: String,
) -> StructuredResponseResult {
    if prompt.trim().is_empty() {
        return StructuredResponseResult::Error {
            message: "prompt is empty".to_string(),
        };
    }
    let schema: serde_json::Value = match serde_json::from_str(&output_schema_json) {
        Ok(v) => v,
        Err(e) => {
            return StructuredResponseResult::Error {
                message: format!("invalid responseFormat JSON schema: {e}"),
            };
        }
    };

    // First attempt: use cached id if provided, otherwise start fresh.
    let mut thread_id = match cached_thread_id {
        Some(id) if !id.trim().is_empty() => id,
        _ => match start_ephemeral_thread_for_structured(client, &server_id).await {
            Ok(id) => id,
            Err(e) => return StructuredResponseResult::Error { message: e },
        },
    };

    match run_structured_turn(client, &server_id, &thread_id, &prompt, schema.clone()).await {
        Ok(text) => StructuredResponseResult::Success {
            thread_id,
            response_json: text,
        },
        Err(StructuredTurnError::StaleThread) => {
            // Cached thread is gone. Reseat and retry exactly once.
            thread_id = match start_ephemeral_thread_for_structured(client, &server_id).await {
                Ok(id) => id,
                Err(e) => {
                    return StructuredResponseResult::Error {
                        message: format!("stale-thread recovery failed: {e}"),
                    };
                }
            };
            match run_structured_turn(client, &server_id, &thread_id, &prompt, schema).await {
                Ok(text) => StructuredResponseResult::Success {
                    thread_id,
                    response_json: text,
                },
                Err(StructuredTurnError::StaleThread) => StructuredResponseResult::Error {
                    message: "thread became stale again on retry".to_string(),
                },
                Err(StructuredTurnError::Fatal(msg)) => {
                    StructuredResponseResult::Error { message: msg }
                }
            }
        }
        Err(StructuredTurnError::Fatal(msg)) => StructuredResponseResult::Error { message: msg },
    }
}

async fn perform_update_saved_app(
    client: &crate::MobileClient,
    server_id: String,
    directory: String,
    app_id: String,
    user_prompt: String,
) -> SavedAppUpdateResult {
    // 1. Load the current saved-app payload so we can seed the thread.
    let current = match crate::saved_apps::saved_app_get(directory.clone(), app_id.clone()) {
        Some(payload) => payload,
        None => {
            return SavedAppUpdateResult::Error {
                message: format!("saved app '{app_id}' not found"),
            };
        }
    };
    let shape_summary = crate::saved_apps::abbreviated_state_shape(&directory, &app_id)
        .unwrap_or_else(|| "  (no saved state yet)".to_string());

    let requested_server_id = server_id;
    let snapshot = client.app_store.snapshot();
    let server_id = match choose_saved_app_update_server_id(&requested_server_id, &snapshot) {
        Some(server_id) => server_id,
        None => {
            return SavedAppUpdateResult::Error {
                message: "saved-app updates require a connected local server because app files live on this device".to_string(),
            };
        }
    };
    if server_id != requested_server_id {
        tracing::info!(
            "update_saved_app: routing edit thread to local server {} instead of requested server {}",
            server_id,
            requested_server_id
        );
    }

    // Inherit the origin thread's model / reasoning / approval / sandbox
    // settings when the thread is still known to the store. Falls back to
    // `None` (server defaults) if the app has no origin_thread_id, or the
    // thread has been archived / never hydrated.
    let inherited = inherited_settings_for_origin(
        client,
        &requested_server_id,
        current.app.origin_thread_id.as_deref(),
    );
    let inherited = if inherited_settings_empty(&inherited) && requested_server_id != server_id {
        inherited_settings_for_origin(client, &server_id, current.app.origin_thread_id.as_deref())
    } else {
        inherited
    };
    let (model, reasoning_effort, approval_policy, sandbox_mode) = inherited;

    // Resolve the on-disk HTML path. The model edits this file directly
    // via apply_patch; no show_widget round-trip needed. cwd is the
    // `html/` directory so `./{app_id}.html` is a valid relative path.
    let apps_root = std::path::Path::new(&directory).join("apps");
    let html_dir = apps_root.join("html");
    let html_filename = format!("{app_id}.html");
    let html_path = html_dir.join(&html_filename);
    let initial_mtime = std::fs::metadata(&html_path)
        .and_then(|m| m.modified())
        .ok();

    let developer_instructions = build_saved_app_update_seed(
        &current.app.title,
        current.app.schema_version,
        &html_filename,
        &shape_summary,
    );

    // 2. Start a hidden ephemeral thread on the server rooted at the
    //    saved-apps HTML directory. The model uses its regular file-
    //    editing tools (apply_patch, shell) to modify the HTML file on
    //    disk — no dynamic_tools, no show_widget round-trip.
    let start_params = upstream::ThreadStartParams {
        model: model.clone(),
        model_provider: None,
        service_tier: None,
        cwd: Some(html_dir.to_string_lossy().into_owned()),
        approval_policy: approval_policy
            .clone()
            .map(crate::types::server_requests::ask_for_approval_into_upstream),
        approvals_reviewer: None,
        sandbox: sandbox_mode
            .clone()
            .map(crate::types::server_requests::sandbox_mode_into_upstream),
        permission_profile: None,
        config: None,
        service_name: None,
        base_instructions: None,
        developer_instructions: Some(developer_instructions),
        personality: None,
        ephemeral: Some(true),
        session_start_source: None,
        dynamic_tools: None,
        mock_experimental_field: None,
        experimental_raw_events: false,
        persist_extended_history: false,
    };
    let thread_response: upstream::ThreadStartResponse = match client
        .request_typed_for_server(
            &server_id,
            upstream::ClientRequest::ThreadStart {
                request_id: upstream::RequestId::Integer(crate::next_request_id()),
                params: start_params,
            },
        )
        .await
    {
        Ok(r) => r,
        Err(e) => {
            return SavedAppUpdateResult::Error {
                message: format!("thread/start failed: {e}"),
            };
        }
    };
    let thread_id = thread_response.thread.id.clone();

    // Hide the thread from the local home/sidebar for the lifetime of
    // the update. Removed on cleanup below.
    let hidden_key = crate::preferences::PinnedThreadKey {
        server_id: server_id.clone(),
        thread_id: thread_id.clone(),
    };
    let _ =
        crate::preferences::preferences_add_hidden_thread(directory.clone(), hidden_key.clone());

    // 3. Subscribe to store updates BEFORE sending the turn so we don't
    //    miss an extremely fast completion. We wait for ThreadMetadataChanged
    //    on our thread with `active_turn_id = None` AND `status = Idle`
    //    AFTER we've seen the turn become active at least once.
    let mut updates_rx = client.app_store.subscribe();

    // 4. Send the user's update prompt on this thread.
    let turn_params = upstream::TurnStartParams {
        thread_id: thread_id.clone(),
        input: vec![upstream::UserInput::Text {
            text: user_prompt.clone(),
            text_elements: Vec::new(),
        }],
        responsesapi_client_metadata: None,
        cwd: None,
        approval_policy: None,
        approvals_reviewer: None,
        sandbox_policy: None,
        environments: None,
        permission_profile: None,
        model,
        service_tier: None,
        effort: reasoning_effort.map(crate::types::server_requests::reasoning_effort_into_upstream),
        summary: None,
        personality: None,
        output_schema: None,
        collaboration_mode: None,
    };
    let turn_start_outcome: Result<upstream::TurnStartResponse, _> = client
        .request_typed_for_server(
            &server_id,
            upstream::ClientRequest::TurnStart {
                request_id: upstream::RequestId::Integer(crate::next_request_id()),
                params: turn_params,
            },
        )
        .await;
    if let Err(e) = turn_start_outcome {
        cleanup_update_thread(client, &server_id, &thread_id, &directory, &hidden_key).await;
        return SavedAppUpdateResult::Error {
            message: format!("turn/start failed: {e}"),
        };
    }

    // 5. Wait for the turn to complete, or time out.
    let wait_outcome = tokio::time::timeout(
        std::time::Duration::from_secs(SAVED_APP_UPDATE_TIMEOUT_SECS),
        async {
            let mut saw_active = false;
            loop {
                match updates_rx.recv().await {
                    Ok(crate::store::updates::AppStoreUpdateRecord::ThreadMetadataChanged {
                        state,
                        ..
                    }) if state.key.thread_id == thread_id && state.key.server_id == server_id => {
                        if state.active_turn_id.is_some() {
                            saw_active = true;
                        } else if saw_active {
                            return Ok(());
                        }
                    }
                    Ok(_) => continue,
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                        return Err("update channel closed".to_string());
                    }
                }
            }
        },
    )
    .await;

    match wait_outcome {
        Ok(Ok(())) => {}
        Ok(Err(e)) => {
            cleanup_update_thread(client, &server_id, &thread_id, &directory, &hidden_key).await;
            return SavedAppUpdateResult::Error { message: e };
        }
        Err(_) => {
            cleanup_update_thread(client, &server_id, &thread_id, &directory, &hidden_key).await;
            return SavedAppUpdateResult::Error {
                message: format!(
                    "update timed out after {SAVED_APP_UPDATE_TIMEOUT_SECS}s waiting for turn to complete"
                ),
            };
        }
    }

    // 6. Read the HTML file from disk — model should have edited it.
    let new_html = match std::fs::read_to_string(&html_path) {
        Ok(html) => html,
        Err(e) => {
            cleanup_update_thread(client, &server_id, &thread_id, &directory, &hidden_key).await;
            return SavedAppUpdateResult::Error {
                message: format!("could not read updated HTML: {e}"),
            };
        }
    };

    // If the file wasn't actually changed, report that — better UX than
    // silently re-saving the same content.
    let new_mtime = std::fs::metadata(&html_path)
        .and_then(|m| m.modified())
        .ok();
    if let (Some(before), Some(after)) = (initial_mtime, new_mtime) {
        if before == after {
            cleanup_update_thread(client, &server_id, &thread_id, &directory, &hidden_key).await;
            return SavedAppUpdateResult::Error {
                message: "no changes were made to the app".to_string(),
            };
        }
    }

    // 7. Write through saved_app_replace_html so the index's updated_at_ms
    //    and any derived fields stay in sync. This re-writes the same
    //    file with the same content, which is fine — the `updated_at_ms`
    //    bump is what downstream listeners (home-row takeover etc.) care
    //    about.
    let replace_result = crate::saved_apps::saved_app_replace_html(
        directory.clone(),
        app_id.clone(),
        new_html,
        current.app.width,
        current.app.height,
    );

    // 8. Clean up the hidden thread regardless of result.
    cleanup_update_thread(client, &server_id, &thread_id, &directory, &hidden_key).await;

    match replace_result {
        Ok(app) => SavedAppUpdateResult::Success { app },
        Err(e) => SavedAppUpdateResult::Error {
            message: format!("replace_html failed: {e}"),
        },
    }
}

fn choose_saved_app_update_server_id(
    requested_server_id: &str,
    snapshot: &crate::store::AppSnapshot,
) -> Option<String> {
    let mut local_server_ids = snapshot
        .servers
        .values()
        .filter(|server| {
            server.is_local
                && matches!(server.health, crate::store::ServerHealthSnapshot::Connected)
        })
        .map(|server| server.server_id.clone())
        .collect::<Vec<_>>();

    if local_server_ids
        .iter()
        .any(|server_id| server_id == requested_server_id)
    {
        return Some(requested_server_id.to_string());
    }
    if local_server_ids
        .iter()
        .any(|server_id| server_id == "local")
    {
        return Some("local".to_string());
    }

    local_server_ids.sort();
    local_server_ids.dedup();
    local_server_ids.into_iter().next()
}

async fn cleanup_update_thread(
    client: &crate::MobileClient,
    server_id: &str,
    thread_id: &str,
    directory: &str,
    hidden_key: &crate::preferences::PinnedThreadKey,
) {
    let _ = crate::preferences::preferences_remove_hidden_thread(
        directory.to_string(),
        hidden_key.clone(),
    );
    let archive_params = upstream::ThreadArchiveParams {
        thread_id: thread_id.to_string(),
    };
    let archive_result: Result<upstream::ThreadArchiveResponse, _> = client
        .request_typed_for_server(
            server_id,
            upstream::ClientRequest::ThreadArchive {
                request_id: upstream::RequestId::Integer(crate::next_request_id()),
                params: archive_params,
            },
        )
        .await;
    if let Err(e) = archive_result {
        tracing::warn!(
            "update_saved_app: failed to archive hidden thread {thread_id}: {e} (ignored)"
        );
    }
}

type InheritedSettings = (
    Option<String>,
    Option<crate::types::models::ReasoningEffort>,
    Option<crate::types::models::AppAskForApproval>,
    Option<crate::types::models::AppSandboxMode>,
);

fn inherited_settings_empty(settings: &InheritedSettings) -> bool {
    settings.0.is_none() && settings.1.is_none() && settings.2.is_none() && settings.3.is_none()
}

/// Look up an origin thread in the app store and extract its effective
/// settings (model / reasoning effort / approval / sandbox mode) so the
/// saved-app update thread can run with the same configuration the user
/// chose for the source conversation. Returns `(None, None, None, None)`
/// when the thread is unknown, never hydrated, or belongs to a different
/// server.
fn inherited_settings_for_origin(
    client: &crate::MobileClient,
    server_id: &str,
    origin_thread_id: Option<&str>,
) -> InheritedSettings {
    use crate::types::models::{AppSandboxMode, AppSandboxPolicy, ReasoningEffort};

    let Some(thread_id) = origin_thread_id.and_then(|s| {
        let t = s.trim();
        if t.is_empty() {
            None
        } else {
            Some(t.to_string())
        }
    }) else {
        return (None, None, None, None);
    };

    let snapshot = client.app_store.snapshot();
    let key = crate::types::ThreadKey {
        server_id: server_id.to_string(),
        thread_id,
    };
    let Some(thread) = snapshot.threads.get(&key) else {
        return (None, None, None, None);
    };

    let model = thread
        .model
        .as_ref()
        .map(|m| m.trim().to_string())
        .filter(|m| !m.is_empty());
    let effort = thread.reasoning_effort.as_deref().and_then(|raw| {
        match raw.trim().to_ascii_lowercase().as_str() {
            "none" => Some(ReasoningEffort::None),
            "minimal" => Some(ReasoningEffort::Minimal),
            "low" => Some(ReasoningEffort::Low),
            "medium" => Some(ReasoningEffort::Medium),
            "high" => Some(ReasoningEffort::High),
            "xhigh" | "x-high" => Some(ReasoningEffort::XHigh),
            _ => None,
        }
    });
    let approval_policy = thread.effective_approval_policy.clone();
    let sandbox_mode = thread.effective_sandbox_policy.as_ref().map(|p| match p {
        AppSandboxPolicy::ReadOnly { .. } | AppSandboxPolicy::ExternalSandbox { .. } => {
            AppSandboxMode::ReadOnly
        }
        AppSandboxPolicy::WorkspaceWrite { .. } => AppSandboxMode::WorkspaceWrite,
        AppSandboxPolicy::DangerFullAccess => AppSandboxMode::DangerFullAccess,
    });
    (model, effort, approval_policy, sandbox_mode)
}

fn build_saved_app_update_seed(
    title: &str,
    schema_version: u32,
    html_filename: &str,
    state_shape_summary: &str,
) -> String {
    let app_guidelines = crate::widget_guidelines::get_guidelines(&["app".to_string()]);
    format!(
        "You are updating an existing saved app called \"{title}\".\n\n\
The app's HTML lives in the current working directory as `./{html_filename}`. \
**Read it first, then edit it with `apply_patch`** (or rewrite it \
wholesale if the change is extensive). Do NOT call `show_widget` — that \
tool is not available on this thread. Your job is to modify the HTML \
file on disk.\n\n\
The app persists user data via `window.loadAppState()` / `window.saveAppState()`. \
The current state schema_version is {schema_version}. You MUST:\n\n\
- Preserve the `loadAppState`/`saveAppState` contract so the user's existing \
data keeps working.\n\
- If state-field shapes changed, migrate them defensively on load.\n\
- Keep the widget self-contained (no cross-file deps; inline CSS/JS is fine).\n\n\
Abbreviated shape of the current persisted state (top-level keys + sample values; \
the raw user data is NOT included):\n\
```\n{{\n{state_shape_summary}\n}}\n```\n\n\
---\n\n\
Widget construction guidelines (for reference when making UI decisions):\n\n\
{app_guidelines}"
    )
}

#[cfg(test)]
mod tests {
    use super::{
        ImageViewSource, choose_saved_app_update_server_id, image_read_command,
        normalized_image_path, splice_generative_ui_preamble,
    };
    use crate::store::snapshot::ServerTransportDiagnostics;
    use crate::store::{AppSnapshot, ServerHealthSnapshot, ServerSnapshot};
    use crate::types::models::AppDynamicToolSpec;
    use crate::widget_guidelines::GENERATIVE_UI_PREAMBLE;
    use std::collections::HashMap;

    fn show_widget_spec() -> AppDynamicToolSpec {
        AppDynamicToolSpec {
            name: "show_widget".to_string(),
            description: "test".to_string(),
            input_schema_json: "{}".to_string(),
            defer_loading: false,
        }
    }

    fn server_snapshot(
        server_id: &str,
        is_local: bool,
        health: ServerHealthSnapshot,
    ) -> ServerSnapshot {
        ServerSnapshot {
            server_id: server_id.to_string(),
            display_name: server_id.to_string(),
            host: "127.0.0.1".to_string(),
            port: 0,
            wake_mac: None,
            is_local,
            supports_ipc: false,
            has_ipc: false,
            health,
            account: None,
            requires_openai_auth: false,
            rate_limits: None,
            available_models: None,
            connection_progress: None,
            transport: ServerTransportDiagnostics::default(),
        }
    }

    fn app_snapshot_with_servers(servers: Vec<ServerSnapshot>) -> AppSnapshot {
        AppSnapshot {
            servers: servers
                .into_iter()
                .map(|server| (server.server_id.clone(), server))
                .collect::<HashMap<_, _>>(),
            ..AppSnapshot::default()
        }
    }

    #[test]
    fn preamble_prepended_when_show_widget_registered() {
        let tools = Some(vec![show_widget_spec()]);
        let result = splice_generative_ui_preamble(&tools, Some("user instructions".to_string()));
        let out = result.expect("expected Some");
        assert!(out.starts_with(GENERATIVE_UI_PREAMBLE));
        assert!(out.ends_with("user instructions"));
    }

    #[test]
    fn preamble_skipped_without_show_widget() {
        let other = AppDynamicToolSpec {
            name: "list_servers".to_string(),
            description: "x".to_string(),
            input_schema_json: "{}".to_string(),
            defer_loading: false,
        };
        let tools = Some(vec![other]);
        let result = splice_generative_ui_preamble(&tools, Some("user instructions".to_string()));
        assert_eq!(result.as_deref(), Some("user instructions"));
    }

    #[test]
    fn preamble_used_alone_when_no_existing_instructions() {
        let tools = Some(vec![show_widget_spec()]);
        assert_eq!(
            splice_generative_ui_preamble(&tools, None).as_deref(),
            Some(GENERATIVE_UI_PREAMBLE)
        );
    }

    #[test]
    fn preamble_skipped_when_no_dynamic_tools() {
        assert_eq!(
            splice_generative_ui_preamble(&None, Some("keep".to_string())).as_deref(),
            Some("keep")
        );
    }

    #[test]
    fn saved_app_update_server_keeps_requested_local_server() {
        let snapshot = app_snapshot_with_servers(vec![
            server_snapshot("local", true, ServerHealthSnapshot::Connected),
            server_snapshot("remote", false, ServerHealthSnapshot::Connected),
        ]);

        let chosen = choose_saved_app_update_server_id("local", &snapshot);
        assert_eq!(chosen.as_deref(), Some("local"));
    }

    #[test]
    fn saved_app_update_server_routes_remote_request_to_local_server() {
        let snapshot = app_snapshot_with_servers(vec![
            server_snapshot("remote", false, ServerHealthSnapshot::Connected),
            server_snapshot("local", true, ServerHealthSnapshot::Connected),
        ]);

        let chosen = choose_saved_app_update_server_id("remote", &snapshot);
        assert_eq!(chosen.as_deref(), Some("local"));
    }

    #[test]
    fn saved_app_update_server_ignores_disconnected_local_server() {
        let snapshot = app_snapshot_with_servers(vec![
            server_snapshot("remote", false, ServerHealthSnapshot::Connected),
            server_snapshot("local", true, ServerHealthSnapshot::Disconnected),
        ]);

        let chosen = choose_saved_app_update_server_id("remote", &snapshot);
        assert_eq!(chosen, None);
    }

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
