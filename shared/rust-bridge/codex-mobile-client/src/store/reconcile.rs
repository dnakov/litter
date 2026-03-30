use std::any::Any;

use crate::MobileClient;
use crate::transport::RpcError;
use crate::types::{ThreadInfo, ThreadKey};
use codex_app_server_protocol as upstream;

impl MobileClient {
    /// Reconcile direct public RPC calls into the canonical app store.
    ///
    /// The public client RPC surface calls this hook after the upstream RPC
    /// returns. The reconciliation policy lives here:
    /// - snapshot/query RPCs reduce authoritative responses directly
    /// - mutations without authoritative payloads trigger targeted refreshes
    /// - event-complete RPCs are no-ops because upstream notifications drive
    ///   the reducer already
    pub async fn reconcile_public_rpc<P: Any, R: Any>(
        &self,
        wire_method: &str,
        server_id: &str,
        params: Option<&P>,
        response: &R,
    ) -> Result<(), RpcError> {
        if wire_method == "turn/start" {
            tracing::info!(
                "reconcile_public_rpc wire_method={} server_id={}",
                wire_method,
                server_id
            );
        }
        match wire_method {
            "thread/start" => {
                let response = downcast_public_rpc_response::<upstream::ThreadStartResponse>(
                    wire_method,
                    response,
                )?;
                self.apply_thread_start_response(server_id, response)
                    .map(|_| ())
                    .map_err(RpcError::Deserialization)
            }
            "thread/list" => {
                let response = downcast_public_rpc_response::<upstream::ThreadListResponse>(
                    wire_method,
                    response,
                )?;
                self.sync_thread_list(server_id, &response.data)
                    .map(|_| ())
                    .map_err(RpcError::Deserialization)
            }
            "thread/read" => {
                let response = downcast_public_rpc_response::<upstream::ThreadReadResponse>(
                    wire_method,
                    response,
                )?;
                self.apply_thread_read_response(server_id, response)
                    .map(|_| ())
                    .map_err(RpcError::Deserialization)
            }
            "thread/resume" => {
                let response = downcast_public_rpc_response::<upstream::ThreadResumeResponse>(
                    wire_method,
                    response,
                )?;
                self.apply_thread_resume_response(server_id, response)
                    .map(|_| ())
                    .map_err(RpcError::Deserialization)
            }
            "thread/fork" => {
                let response = downcast_public_rpc_response::<upstream::ThreadForkResponse>(
                    wire_method,
                    response,
                )?;
                self.apply_thread_fork_response(server_id, response)
                    .map(|_| ())
                    .map_err(RpcError::Deserialization)
            }
            "thread/rollback" => {
                let response = downcast_public_rpc_response::<upstream::ThreadRollbackResponse>(
                    wire_method,
                    response,
                )?;
                let params = downcast_public_rpc_params::<upstream::ThreadRollbackParams>(
                    wire_method,
                    params.map(|value| value as &dyn Any),
                )?;
                self.apply_thread_rollback_response(server_id, &params.thread_id, response)
                    .map(|_| ())
                    .map_err(RpcError::Deserialization)
            }
            "account/read" => {
                let response = downcast_public_rpc_response::<upstream::GetAccountResponse>(
                    wire_method,
                    response,
                )?;
                self.apply_account_response(server_id, response);
                Ok(())
            }
            "account/rateLimits/read" => {
                let response = downcast_public_rpc_response::<
                    upstream::GetAccountRateLimitsResponse,
                >(wire_method, response)?;
                self.apply_account_rate_limits_response(server_id, response);
                Ok(())
            }
            "model/list" => {
                let response = downcast_public_rpc_response::<upstream::ModelListResponse>(
                    wire_method,
                    response,
                )?;
                self.apply_model_list_response(server_id, response);
                Ok(())
            }
            "account/login/start" => self.sync_server_account(server_id).await,
            "account/logout" => self.sync_server_account_after_logout(server_id).await,
            _ => Ok(()),
        }
    }

    pub(crate) fn clear_server_account(&self, server_id: &str) {
        self.app_store.update_server_account(server_id, None, false);
    }

    pub(crate) fn apply_account_response(
        &self,
        server_id: &str,
        response: &upstream::GetAccountResponse,
    ) {
        self.app_store.update_server_account(
            server_id,
            response.account.clone().map(Into::into),
            response.requires_openai_auth,
        );
    }

    pub(crate) fn apply_account_rate_limits_response(
        &self,
        server_id: &str,
        response: &upstream::GetAccountRateLimitsResponse,
    ) {
        self.app_store
            .update_server_rate_limits(server_id, Some(response.rate_limits.clone().into()));
    }

    pub(crate) fn apply_model_list_response(
        &self,
        server_id: &str,
        response: &upstream::ModelListResponse,
    ) {
        self.app_store.update_server_models(
            server_id,
            Some(response.data.iter().cloned().map(Into::into).collect()),
        );
    }

    pub(crate) fn sync_thread_list(
        &self,
        server_id: &str,
        threads: &[upstream::Thread],
    ) -> Result<Vec<ThreadInfo>, String> {
        let threads = threads
            .iter()
            .cloned()
            .filter_map(crate::thread_info_from_upstream_thread)
            .collect::<Vec<_>>();
        self.app_store.sync_thread_list(server_id, &threads);
        Ok(threads)
    }

    pub(crate) async fn sync_server_account_after_logout(
        &self,
        server_id: &str,
    ) -> Result<(), RpcError> {
        match self.sync_server_account(server_id).await {
            Ok(()) => Ok(()),
            Err(error) => {
                self.clear_server_account(server_id);
                Err(error)
            }
        }
    }

    pub(crate) fn apply_thread_start_response(
        &self,
        server_id: &str,
        response: &upstream::ThreadStartResponse,
    ) -> Result<ThreadKey, String> {
        let snapshot = crate::thread_snapshot_from_upstream_thread_with_overrides(
            server_id,
            response.thread.clone(),
            Some(response.model.clone()),
            response
                .reasoning_effort
                .map(Into::into)
                .map(crate::reasoning_effort_string),
        )
        .map_err(|e| e.to_string())?;
        let key = snapshot.key.clone();
        self.app_store.upsert_thread_snapshot(snapshot);
        Ok(key)
    }

    pub(crate) fn apply_thread_read_response(
        &self,
        server_id: &str,
        response: &upstream::ThreadReadResponse,
    ) -> Result<ThreadKey, String> {
        let snapshot = crate::thread_snapshot_from_upstream_thread_with_overrides(
            server_id,
            response.thread.clone(),
            None,
            None,
        )
        .map_err(|e| e.to_string())?;
        let key = snapshot.key.clone();
        self.app_store.upsert_thread_snapshot(snapshot);
        Ok(key)
    }

    pub(crate) fn apply_thread_resume_response(
        &self,
        server_id: &str,
        response: &upstream::ThreadResumeResponse,
    ) -> Result<ThreadKey, String> {
        let snapshot = crate::thread_snapshot_from_upstream_thread_with_overrides(
            server_id,
            response.thread.clone(),
            Some(response.model.clone()),
            response
                .reasoning_effort
                .map(Into::into)
                .map(crate::reasoning_effort_string),
        )
        .map_err(|e| e.to_string())?;
        let key = snapshot.key.clone();
        self.app_store.upsert_thread_snapshot(snapshot);
        Ok(key)
    }

    pub(crate) fn apply_thread_fork_response(
        &self,
        server_id: &str,
        response: &upstream::ThreadForkResponse,
    ) -> Result<ThreadKey, String> {
        let snapshot = crate::thread_snapshot_from_upstream_thread_with_overrides(
            server_id,
            response.thread.clone(),
            Some(response.model.clone()),
            response
                .reasoning_effort
                .map(Into::into)
                .map(crate::reasoning_effort_string),
        )
        .map_err(|e| e.to_string())?;
        let key = snapshot.key.clone();
        self.app_store.upsert_thread_snapshot(snapshot);
        Ok(key)
    }

    pub(crate) fn apply_thread_rollback_response(
        &self,
        server_id: &str,
        thread_id: &str,
        response: &upstream::ThreadRollbackResponse,
    ) -> Result<ThreadKey, String> {
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };
        let current = self.app_store.thread_snapshot(&key);
        let mut snapshot = crate::thread_snapshot_from_upstream_thread_with_overrides(
            server_id,
            response.thread.clone(),
            current.as_ref().and_then(|thread| thread.model.clone()),
            current.as_ref().and_then(|thread| {
                thread
                    .reasoning_effort
                    .as_deref()
                    .and_then(crate::reasoning_effort_from_string)
                    .map(crate::reasoning_effort_string)
            }),
        )
        .map_err(|e| e.to_string())?;
        if let Some(current) = current.as_ref() {
            crate::copy_thread_runtime_fields(current, &mut snapshot);
        }
        let next_key = snapshot.key.clone();
        self.app_store.upsert_thread_snapshot(snapshot);
        Ok(next_key)
    }
}

fn downcast_public_rpc_response<'a, T: Any>(
    wire_method: &str,
    response: &'a dyn Any,
) -> Result<&'a T, RpcError> {
    response.downcast_ref::<T>().ok_or_else(|| {
        RpcError::Deserialization(format!(
            "unexpected response type while reconciling {wire_method}"
        ))
    })
}

fn downcast_public_rpc_params<'a, T: Any>(
    wire_method: &str,
    params: Option<&'a dyn Any>,
) -> Result<&'a T, RpcError> {
    params
        .and_then(|value| value.downcast_ref::<T>())
        .ok_or_else(|| {
            RpcError::Deserialization(format!(
                "unexpected params type while reconciling {wire_method}"
            ))
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::connection::ServerConfig;
    use crate::store::ServerHealthSnapshot;
    use codex_app_server_protocol as upstream;
    use std::path::PathBuf;

    fn test_upstream_thread(id: &str) -> upstream::Thread {
        upstream::Thread {
            id: id.to_string(),
            preview: "hello".to_string(),
            ephemeral: false,
            model_provider: "openai".to_string(),
            created_at: 1,
            updated_at: 2,
            status: upstream::ThreadStatus::Idle,
            path: Some(PathBuf::from("/tmp/thread.jsonl")),
            cwd: PathBuf::from("/tmp"),
            cli_version: "1.0.0".to_string(),
            source: upstream::SessionSource::default(),
            agent_nickname: None,
            agent_role: None,
            git_info: None,
            name: Some("Thread".to_string()),
            turns: Vec::new(),
        }
    }

    #[tokio::test]
    async fn account_read_reconciliation_updates_store() {
        let client = MobileClient::new();
        client.app_store.upsert_server(
            &ServerConfig {
                server_id: "srv".into(),
                display_name: "Server".into(),
                host: "127.0.0.1".into(),
                port: 9234,
                websocket_url: None,
                is_local: true,
                tls: false,
            },
            ServerHealthSnapshot::Connected,
        );

        let response = upstream::GetAccountResponse {
            account: Some(upstream::Account::Chatgpt {
                email: "user@example.com".into(),
                plan_type: codex_protocol::account::PlanType::Pro,
            }),
            requires_openai_auth: true,
        };

        client
            .reconcile_public_rpc("account/read", "srv", Option::<&()>::None, &response)
            .await
            .expect("account/read reconciliation should succeed");

        let snapshot = client.app_snapshot();
        let server = snapshot
            .servers
            .get("srv")
            .expect("server should still exist");
        assert_eq!(server.account, response.account.clone().map(Into::into));
        assert!(server.requires_openai_auth);
    }

    #[tokio::test]
    async fn account_rate_limits_reconciliation_updates_store() {
        let client = MobileClient::new();
        client.app_store.upsert_server(
            &ServerConfig {
                server_id: "srv".to_string(),
                display_name: "Server".to_string(),
                host: "localhost".to_string(),
                port: 8390,
                websocket_url: None,
                is_local: true,
                tls: false,
            },
            ServerHealthSnapshot::Connected,
        );

        let response = upstream::GetAccountRateLimitsResponse {
            rate_limits: upstream::RateLimitSnapshot {
                limit_id: Some("primary".to_string()),
                limit_name: Some("Primary".to_string()),
                primary: Some(upstream::RateLimitWindow {
                    used_percent: 42,
                    window_duration_mins: Some(60),
                    resets_at: Some(123456789),
                }),
                secondary: None,
                credits: Some(upstream::CreditsSnapshot {
                    has_credits: true,
                    unlimited: false,
                    balance: Some("5.00".to_string()),
                }),
                plan_type: Some(codex_protocol::account::PlanType::Plus),
            },
            rate_limits_by_limit_id: None,
        };

        client
            .reconcile_public_rpc(
                "account/rateLimits/read",
                "srv",
                Option::<&()>::None,
                &response,
            )
            .await
            .expect("account/rateLimits/read reconciliation should succeed");

        let snapshot = client.app_snapshot();
        let server = snapshot
            .servers
            .get("srv")
            .expect("server snapshot should exist");
        assert_eq!(
            server.rate_limits,
            Some(response.rate_limits.clone().into())
        );
    }

    #[tokio::test]
    async fn model_list_reconciliation_updates_store() {
        let client = MobileClient::new();
        client.app_store.upsert_server(
            &ServerConfig {
                server_id: "srv".to_string(),
                display_name: "Server".to_string(),
                host: "localhost".to_string(),
                port: 8390,
                websocket_url: None,
                is_local: true,
                tls: false,
            },
            ServerHealthSnapshot::Connected,
        );

        let response = upstream::ModelListResponse {
            data: vec![upstream::Model {
                id: "gpt-5.4".to_string(),
                model: "gpt-5.4".to_string(),
                upgrade: None,
                display_name: "gpt-5.4".to_string(),
                description: "Balanced flagship".to_string(),
                hidden: false,
                supported_reasoning_efforts: vec![upstream::ReasoningEffortOption {
                    reasoning_effort: codex_protocol::openai_models::ReasoningEffort::Medium,
                    description: "Balanced".to_string(),
                }],
                default_reasoning_effort: codex_protocol::openai_models::ReasoningEffort::Medium,
                input_modalities: vec![codex_protocol::openai_models::InputModality::Text],
                supports_personality: true,
                is_default: true,
                availability_nux: None,
                upgrade_info: None,
            }],
            next_cursor: None,
        };

        client
            .reconcile_public_rpc("model/list", "srv", Option::<&()>::None, &response)
            .await
            .expect("model/list reconciliation should succeed");

        let snapshot = client.app_snapshot();
        let server = snapshot
            .servers
            .get("srv")
            .expect("server snapshot should exist");
        assert_eq!(
            server.available_models,
            Some(response.data.into_iter().map(Into::into).collect())
        );
    }

    #[tokio::test]
    async fn thread_reconciliation_param_handling_matches_wire_method() {
        let client = MobileClient::new();
        client.app_store.upsert_server(
            &ServerConfig {
                server_id: "srv".to_string(),
                display_name: "Server".to_string(),
                host: "localhost".to_string(),
                port: 8390,
                websocket_url: None,
                is_local: true,
                tls: false,
            },
            ServerHealthSnapshot::Connected,
        );

        let list_response = upstream::ThreadListResponse {
            data: vec![test_upstream_thread("thread-1")],
            next_cursor: None,
        };

        client
            .reconcile_public_rpc("thread/list", "srv", Option::<&()>::None, &list_response)
            .await
            .expect("thread/list reconciliation should succeed without params");

        let rollback_response = upstream::ThreadRollbackResponse {
            thread: test_upstream_thread("thread-1"),
        };

        let missing_params_error = client
            .reconcile_public_rpc(
                "thread/rollback",
                "srv",
                Option::<&()>::None,
                &rollback_response,
            )
            .await
            .expect_err("thread/rollback should reject missing params");
        assert!(
            missing_params_error
                .to_string()
                .contains("unexpected params type while reconciling thread/rollback")
        );

        let params = upstream::ThreadRollbackParams {
            thread_id: "thread-1".to_string(),
            num_turns: 1,
        };
        client
            .reconcile_public_rpc("thread/rollback", "srv", Some(&params), &rollback_response)
            .await
            .expect("thread/rollback reconciliation should succeed with params");

        let snapshot = client.app_snapshot();
        assert!(snapshot.threads.contains_key(&ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-1".to_string(),
        }));
    }
}
