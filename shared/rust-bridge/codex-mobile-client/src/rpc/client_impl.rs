//! Internal typed app-server helpers for `MobileClient`.
//!
//! These stay Rust-internal so the public UniFFI boundary can remain
//! handwritten and mobile-owned.

use super::{RpcClientError, next_request_id};
use crate::MobileClient;
use codex_app_server_protocol as upstream;

impl MobileClient {
    async fn request_rpc<T>(
        &self,
        server_id: &str,
        request: upstream::ClientRequest,
    ) -> Result<T, RpcClientError>
    where
        T: serde::de::DeserializeOwned,
    {
        self.request_typed_for_server(server_id, request)
            .await
            .map_err(RpcClientError::Rpc)
    }
}

macro_rules! rpc_method {
    ($name:ident, $param_ty:path, $resp_ty:path, $variant:ident) => {
        pub async fn $name(
            &self,
            server_id: &str,
            params: $param_ty,
        ) -> Result<$resp_ty, RpcClientError> {
            self.request_rpc(
                server_id,
                upstream::ClientRequest::$variant {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params,
                },
            )
            .await
        }
    };
}

macro_rules! rpc_method_no_params {
    ($name:ident, $resp_ty:path, $variant:ident) => {
        pub async fn $name(&self, server_id: &str) -> Result<$resp_ty, RpcClientError> {
            self.request_rpc(
                server_id,
                upstream::ClientRequest::$variant {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params: None,
                },
            )
            .await
        }
    };
}

impl MobileClient {
    rpc_method!(
        server_thread_start,
        upstream::ThreadStartParams,
        upstream::ThreadStartResponse,
        ThreadStart
    );
    rpc_method!(
        server_thread_resume,
        upstream::ThreadResumeParams,
        upstream::ThreadResumeResponse,
        ThreadResume
    );
    rpc_method!(
        server_thread_fork,
        upstream::ThreadForkParams,
        upstream::ThreadForkResponse,
        ThreadFork
    );
    rpc_method!(
        server_thread_archive,
        upstream::ThreadArchiveParams,
        upstream::ThreadArchiveResponse,
        ThreadArchive
    );
    rpc_method!(
        server_thread_set_name,
        upstream::ThreadSetNameParams,
        upstream::ThreadSetNameResponse,
        ThreadSetName
    );
    rpc_method!(
        server_thread_rollback,
        upstream::ThreadRollbackParams,
        upstream::ThreadRollbackResponse,
        ThreadRollback
    );
    rpc_method!(
        server_thread_list,
        upstream::ThreadListParams,
        upstream::ThreadListResponse,
        ThreadList
    );
    rpc_method!(
        server_turn_start,
        upstream::TurnStartParams,
        upstream::TurnStartResponse,
        TurnStart
    );
    rpc_method!(
        server_turn_interrupt,
        upstream::TurnInterruptParams,
        upstream::TurnInterruptResponse,
        TurnInterrupt
    );
    rpc_method!(
        server_get_account,
        upstream::GetAccountParams,
        upstream::GetAccountResponse,
        GetAccount
    );
    rpc_method_no_params!(
        server_logout_account,
        upstream::LogoutAccountResponse,
        LogoutAccount
    );
    rpc_method_no_params!(
        server_get_account_rate_limits,
        upstream::GetAccountRateLimitsResponse,
        GetAccountRateLimits
    );
}
