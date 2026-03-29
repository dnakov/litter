use std::any::Any;

use crate::MobileClient;
use crate::transport::RpcError;
use crate::types::{ThreadInfo, ThreadKey, generated};

impl MobileClient {
    /// Reconcile direct public RPC calls into the canonical app store.
    ///
    /// The generated UniFFI RPC surface always calls this hook after the
    /// upstream RPC returns. The reconciliation policy lives here, not in
    /// codegen:
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
                let response = downcast_public_rpc_response::<generated::ThreadStartResponse>(
                    wire_method,
                    response,
                )?;
                self.apply_thread_start_response(server_id, response)
                    .map(|_| ())
                    .map_err(RpcError::Deserialization)
            }
            "thread/list" => {
                let response = downcast_public_rpc_response::<generated::ThreadListResponse>(
                    wire_method,
                    response,
                )?;
                self.sync_generated_thread_list(server_id, &response.data)
                    .map(|_| ())
                    .map_err(RpcError::Deserialization)
            }
            "thread/read" => {
                let response = downcast_public_rpc_response::<generated::ThreadReadResponse>(
                    wire_method,
                    response,
                )?;
                self.apply_thread_read_response(server_id, response)
                    .map(|_| ())
                    .map_err(RpcError::Deserialization)
            }
            "thread/resume" => {
                let response = downcast_public_rpc_response::<generated::ThreadResumeResponse>(
                    wire_method,
                    response,
                )?;
                self.apply_thread_resume_response(server_id, response)
                    .map(|_| ())
                    .map_err(RpcError::Deserialization)
            }
            "thread/fork" => {
                let response = downcast_public_rpc_response::<generated::ThreadForkResponse>(
                    wire_method,
                    response,
                )?;
                self.apply_thread_fork_response(server_id, response)
                    .map(|_| ())
                    .map_err(RpcError::Deserialization)
            }
            "thread/rollback" => {
                let response = downcast_public_rpc_response::<generated::ThreadRollbackResponse>(
                    wire_method,
                    response,
                )?;
                let params = downcast_public_rpc_params::<generated::ThreadRollbackParams>(
                    wire_method,
                    params.map(|value| value as &dyn Any),
                )?;
                self.apply_thread_rollback_response(server_id, &params.thread_id, response)
                    .map(|_| ())
                    .map_err(RpcError::Deserialization)
            }
            "account/read" => {
                let response = downcast_public_rpc_response::<generated::GetAccountResponse>(
                    wire_method,
                    response,
                )?;
                self.apply_account_response(server_id, response);
                Ok(())
            }
            "account/rateLimits/read" => {
                let response = downcast_public_rpc_response::<
                    generated::GetAccountRateLimitsResponse,
                >(wire_method, response)?;
                self.apply_account_rate_limits_response(server_id, response);
                Ok(())
            }
            "model/list" => {
                let response = downcast_public_rpc_response::<generated::ModelListResponse>(
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
        response: &generated::GetAccountResponse,
    ) {
        self.app_store.update_server_account(
            server_id,
            response.account.clone(),
            response.requires_openai_auth,
        );
    }

    pub(crate) fn apply_account_rate_limits_response(
        &self,
        server_id: &str,
        response: &generated::GetAccountRateLimitsResponse,
    ) {
        self.app_store
            .update_server_rate_limits(server_id, Some(response.rate_limits.clone()));
    }

    pub(crate) fn apply_model_list_response(
        &self,
        server_id: &str,
        response: &generated::ModelListResponse,
    ) {
        self.app_store
            .update_server_models(server_id, Some(response.data.clone()));
    }

    pub(crate) fn sync_generated_thread_list(
        &self,
        server_id: &str,
        threads: &[generated::Thread],
    ) -> Result<Vec<ThreadInfo>, String> {
        let threads = threads
            .iter()
            .cloned()
            .filter_map(crate::thread_info_from_generated_thread)
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
        response: &generated::ThreadStartResponse,
    ) -> Result<ThreadKey, String> {
        let snapshot = crate::thread_snapshot_from_generated_thread(
            server_id,
            response.thread.clone(),
            Some(response.model.clone()),
            response
                .reasoning_effort
                .clone()
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
        response: &generated::ThreadReadResponse,
    ) -> Result<ThreadKey, String> {
        let snapshot = crate::thread_snapshot_from_generated_thread(
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
        response: &generated::ThreadResumeResponse,
    ) -> Result<ThreadKey, String> {
        let snapshot = crate::thread_snapshot_from_generated_thread(
            server_id,
            response.thread.clone(),
            Some(response.model.clone()),
            response
                .reasoning_effort
                .clone()
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
        response: &generated::ThreadForkResponse,
    ) -> Result<ThreadKey, String> {
        let snapshot = crate::thread_snapshot_from_generated_thread(
            server_id,
            response.thread.clone(),
            Some(response.model.clone()),
            response
                .reasoning_effort
                .clone()
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
        response: &generated::ThreadRollbackResponse,
    ) -> Result<ThreadKey, String> {
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };
        let current = self.app_store.thread_snapshot(&key);
        let mut snapshot = crate::thread_snapshot_from_generated_thread(
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

        let response = generated::GetAccountResponse {
            account: Some(generated::Account::Chatgpt {
                email: "user@example.com".into(),
                plan_type: generated::PlanType::Pro,
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
        assert_eq!(server.account, response.account);
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

        let response = generated::GetAccountRateLimitsResponse {
            rate_limits: generated::RateLimitSnapshot {
                limit_id: Some("primary".to_string()),
                limit_name: Some("Primary".to_string()),
                primary: Some(generated::RateLimitWindow {
                    used_percent: 42,
                    window_duration_mins: Some(60),
                    resets_at: Some(123456789),
                }),
                secondary: None,
                credits: Some(generated::CreditsSnapshot {
                    has_credits: true,
                    unlimited: false,
                    balance: Some("5.00".to_string()),
                }),
                plan_type: Some(generated::PlanType::Plus),
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
        assert_eq!(server.rate_limits, Some(response.rate_limits));
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

        let response = generated::ModelListResponse {
            data: vec![generated::Model {
                id: "gpt-5.4".to_string(),
                model: "gpt-5.4".to_string(),
                upgrade: None,
                upgrade_info: None,
                availability_nux: None,
                display_name: "gpt-5.4".to_string(),
                description: "Balanced flagship".to_string(),
                hidden: false,
                supported_reasoning_efforts: vec![generated::ReasoningEffortOption {
                    reasoning_effort: generated::ReasoningEffort::Medium,
                    description: "Balanced".to_string(),
                }],
                default_reasoning_effort: generated::ReasoningEffort::Medium,
                input_modalities: vec![generated::InputModality::Text],
                supports_personality: true,
                is_default: true,
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
        assert_eq!(server.available_models, Some(response.data));
    }
}
