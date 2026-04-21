#[cfg(test)]
mod mobile_client_tests {
    use super::super::*;
    use crate::conversation_uniffi::HydratedConversationItemContent;
    use crate::session::connection::{TestRequestHandler, TestResolveHandler};
    use crate::store::AppStoreUpdateRecord;
    use crate::store::updates::ThreadStreamingDeltaKind;
    use crate::types::ThreadSummaryStatus;
    use crate::types::{PendingUserInputOption, PendingUserInputQuestion};
    use codex_ipc::{Envelope, InitializeResult, Method, Response};
    use serde_json::json;
    use std::collections::HashMap;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex as StdMutex};
    use std::time::Duration;
    use tokio::sync::broadcast::error::TryRecvError;
    use tokio::time::{Instant, sleep};

    fn drain_app_updates(
        rx: &mut tokio::sync::broadcast::Receiver<AppStoreUpdateRecord>,
    ) -> Vec<AppStoreUpdateRecord> {
        let mut updates = Vec::new();
        loop {
            match rx.try_recv() {
                Ok(update) => updates.push(update),
                Err(TryRecvError::Empty) | Err(TryRecvError::Closed) => break,
                Err(TryRecvError::Lagged(_)) => continue,
            }
        }
        updates
    }

    fn make_thread_info(id: &str) -> ThreadInfo {
        ThreadInfo {
            id: id.to_string(),
            title: Some("Thread".to_string()),
            model: None,
            status: ThreadSummaryStatus::Active,
            preview: Some("preview".to_string()),
            cwd: Some("/tmp".to_string()),
            path: Some("/tmp".to_string()),
            model_provider: Some("openai".to_string()),
            agent_nickname: None,
            agent_role: None,
            parent_thread_id: None,
            agent_status: None,
            created_at: Some(1),
            updated_at: Some(2),
        }
    }

    fn make_user_input_request(question: PendingUserInputQuestion) -> PendingUserInputRequest {
        PendingUserInputRequest {
            id: "req-1".to_string(),
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
            turn_id: "turn-1".to_string(),
            item_id: "item-1".to_string(),
            questions: vec![question],
            requester_agent_nickname: None,
            requester_agent_role: None,
        }
    }

    fn make_server_config(server_id: &str) -> ServerConfig {
        ServerConfig {
            server_id: server_id.to_string(),
            display_name: server_id.to_string(),
            host: "127.0.0.1".to_string(),
            port: 0,
            websocket_url: Some("ws://127.0.0.1:0".to_string()),
            is_local: false,
            tls: false,
            backend_kind: crate::session::connection::AppServerBackendKind::Codex,
            transport_kind: crate::session::connection::AppServerTransportKind::Websocket,
            connection_path: crate::session::connection::AppServerConnectionPath::Lan,
            known_directories: Vec::new(),
        }
    }

    async fn connect_test_ipc_client(label: &str) -> IpcClient {
        let (client_stream, mut server_stream) = tokio::io::duplex(4096);
        let label = label.to_string();
        let router_label = label.clone();
        let client_label = label.clone();
        tokio::spawn(async move {
            let raw = codex_ipc::transport::frame::read_frame(&mut server_stream)
                .await
                .expect("initialize request frame");
            let envelope: Envelope = serde_json::from_str(&raw).expect("initialize envelope");
            let request = match envelope {
                Envelope::Request(request) => request,
                other => panic!("expected initialize request, got {other:?}"),
            };
            assert_eq!(request.method, Method::Initialize.wire_name());

            let response = Envelope::Response(Response::Success {
                request_id: request.request_id,
                method: request.method,
                handled_by_client_id: format!("router-{router_label}"),
                result: serde_json::to_value(InitializeResult {
                    client_id: format!("client-{client_label}"),
                })
                .expect("initialize result"),
            });
            codex_ipc::transport::frame::write_frame(
                &mut server_stream,
                &serde_json::to_string(&response).expect("response json"),
            )
            .await
            .expect("initialize response write");

            let _ = codex_ipc::transport::frame::read_frame(&mut server_stream).await;
        });

        IpcClient::connect_with_stream(
            &IpcClientConfig {
                socket_path: PathBuf::from(format!("/tmp/{label}.sock")),
                client_type: "mobile-test".to_string(),
                request_timeout: Duration::from_secs(1),
            },
            client_stream,
        )
        .await
        .expect("ipc client should connect")
    }

    async fn connect_error_ipc_client(label: &str, error: &str) -> IpcClient {
        let (client_stream, mut server_stream) = tokio::io::duplex(4096);
        let label = label.to_string();
        let router_label = label.clone();
        let client_label = label.clone();
        let request_error = error.to_string();
        tokio::spawn(async move {
            let raw = codex_ipc::transport::frame::read_frame(&mut server_stream)
                .await
                .expect("initialize request frame");
            let envelope: Envelope = serde_json::from_str(&raw).expect("initialize envelope");
            let request = match envelope {
                Envelope::Request(request) => request,
                other => panic!("expected initialize request, got {other:?}"),
            };
            assert_eq!(request.method, Method::Initialize.wire_name());

            let response = Envelope::Response(Response::Success {
                request_id: request.request_id,
                method: request.method,
                handled_by_client_id: format!("router-{router_label}"),
                result: serde_json::to_value(InitializeResult {
                    client_id: format!("client-{client_label}"),
                })
                .expect("initialize result"),
            });
            codex_ipc::transport::frame::write_frame(
                &mut server_stream,
                &serde_json::to_string(&response).expect("response json"),
            )
            .await
            .expect("initialize response write");

            while let Ok(raw) = codex_ipc::transport::frame::read_frame(&mut server_stream).await {
                let envelope: Envelope =
                    serde_json::from_str(&raw).expect("request envelope after initialize");
                let request = match envelope {
                    Envelope::Request(request) => request,
                    other => panic!("expected request after initialize, got {other:?}"),
                };
                let response = Envelope::Response(Response::Error {
                    request_id: request.request_id,
                    error: request_error.clone(),
                });
                codex_ipc::transport::frame::write_frame(
                    &mut server_stream,
                    &serde_json::to_string(&response).expect("error response json"),
                )
                .await
                .expect("error response write");
            }
        });

        IpcClient::connect_with_stream(
            &IpcClientConfig {
                socket_path: PathBuf::from(format!("/tmp/{label}-err.sock")),
                client_type: "mobile-test".to_string(),
                request_timeout: Duration::from_secs(1),
            },
            client_stream,
        )
        .await
        .expect("ipc client should connect")
    }

    async fn make_reconnecting_ipc_client(
        connect_count: Arc<AtomicUsize>,
        reconnect_delay: Duration,
    ) -> ReconnectingIpcClient {
        ReconnectingIpcClient::start_with_connector(
            None,
            move || {
                let connect_count = Arc::clone(&connect_count);
                async move {
                    let attempt = connect_count.fetch_add(1, Ordering::SeqCst) + 1;
                    if reconnect_delay > Duration::ZERO {
                        sleep(reconnect_delay).await;
                    }
                    Ok(connect_test_ipc_client(&attempt.to_string()).await)
                }
            },
            ReconnectPolicy {
                initial_delay: Duration::from_millis(1),
                max_delay: Duration::from_millis(5),
                max_attempts: Some(16),
            },
        )
    }

    async fn make_error_reconnecting_ipc_client(
        connect_count: Arc<AtomicUsize>,
        reconnect_delay: Duration,
        error: &'static str,
    ) -> ReconnectingIpcClient {
        ReconnectingIpcClient::start_with_connector(
            None,
            move || {
                let connect_count = Arc::clone(&connect_count);
                async move {
                    let attempt = connect_count.fetch_add(1, Ordering::SeqCst) + 1;
                    if reconnect_delay > Duration::ZERO {
                        sleep(reconnect_delay).await;
                    }
                    Ok(connect_error_ipc_client(&attempt.to_string(), error).await)
                }
            },
            ReconnectPolicy {
                initial_delay: Duration::from_millis(1),
                max_delay: Duration::from_millis(5),
                max_attempts: Some(16),
            },
        )
    }

    async fn wait_until(timeout: Duration, mut predicate: impl FnMut() -> bool) {
        let deadline = Instant::now() + timeout;
        loop {
            if predicate() {
                return;
            }
            assert!(Instant::now() < deadline, "timed out waiting for condition");
            sleep(Duration::from_millis(5)).await;
        }
    }

    fn thread_snapshot_with_active_turn(
        server_id: &str,
        thread_id: &str,
        active_turn_id: &str,
    ) -> ThreadSnapshot {
        let mut thread = ThreadSnapshot::from_info(server_id, make_thread_info(thread_id));
        thread.active_turn_id = Some(active_turn_id.to_string());
        thread
    }

    #[test]
    fn reasoning_effort_parsing_accepts_known_values() {
        assert_eq!(
            reasoning_effort_from_string("low"),
            Some(crate::types::ReasoningEffort::Low)
        );
        assert_eq!(
            reasoning_effort_from_string("MEDIUM"),
            Some(crate::types::ReasoningEffort::Medium)
        );
        assert_eq!(
            reasoning_effort_from_string(" high "),
            Some(crate::types::ReasoningEffort::High)
        );
        assert_eq!(reasoning_effort_from_string(""), None);
    }

    #[test]
    fn normalize_pending_user_input_wraps_freeform_answers_as_notes() {
        let request = make_user_input_request(PendingUserInputQuestion {
            id: "q-1".to_string(),
            header: None,
            question: "Explain the choice".to_string(),
            is_other_allowed: true,
            is_secret: false,
            options: Vec::new(),
        });

        let normalized = normalize_pending_user_input_answers(
            &request,
            &[PendingUserInputAnswer {
                question_id: "q-1".to_string(),
                answers: vec!["Need to update the reducer".to_string()],
            }],
        );

        assert_eq!(
            normalized,
            vec![PendingUserInputAnswer {
                question_id: "q-1".to_string(),
                answers: vec!["user_note: Need to update the reducer".to_string()],
            }]
        );
    }

    #[test]
    fn normalize_pending_user_input_injects_other_option_for_custom_answers() {
        let request = make_user_input_request(PendingUserInputQuestion {
            id: "q-1".to_string(),
            header: None,
            question: "Choose one".to_string(),
            is_other_allowed: true,
            is_secret: false,
            options: vec![PendingUserInputOption {
                label: "Option A".to_string(),
                description: None,
            }],
        });

        let normalized = normalize_pending_user_input_answers(
            &request,
            &[PendingUserInputAnswer {
                question_id: "q-1".to_string(),
                answers: vec!["My custom answer".to_string()],
            }],
        );

        assert_eq!(
            normalized,
            vec![PendingUserInputAnswer {
                question_id: "q-1".to_string(),
                answers: vec![
                    "None of the above".to_string(),
                    "user_note: My custom answer".to_string(),
                ],
            }]
        );
    }

    #[test]
    fn ipc_pending_user_input_submission_id_uses_request_id() {
        let request = make_user_input_request(PendingUserInputQuestion {
            id: "q-1".to_string(),
            header: None,
            question: "Choose one".to_string(),
            is_other_allowed: false,
            is_secret: false,
            options: Vec::new(),
        });

        assert_eq!(ipc_pending_user_input_submission_id(&request), "req-1");
    }

    #[test]
    fn copy_thread_runtime_fields_preserves_existing_runtime_state() {
        let source = ThreadSnapshot {
            key: ThreadKey {
                server_id: "srv".to_string(),
                thread_id: "thread-1".to_string(),
            },
            info: make_thread_info("thread-1"),
            collaboration_mode: AppModeKind::Plan,
            model: Some("gpt-5".to_string()),
            reasoning_effort: Some("high".to_string()),
            effective_approval_policy: None,
            effective_sandbox_policy: None,
            items: Vec::new(),
            local_overlay_items: Vec::new(),
            queued_follow_ups: vec![AppQueuedFollowUpPreview {
                id: "queued-1".to_string(),
                kind: AppQueuedFollowUpKind::Message,
                text: "follow-up".to_string(),
            }],
            queued_follow_up_drafts: Vec::new(),
            active_turn_id: Some("turn-1".to_string()),
            context_tokens_used: Some(12_345),
            model_context_window: Some(200_000),
            rate_limits: Some(crate::types::RateLimits {
                requests_remaining: Some(10),
                tokens_remaining: Some(20_000),
                reset_at: Some("2026-03-25T12:00:00Z".to_string()),
            }),
            realtime_session_id: Some("rt-1".to_string()),
            active_plan_progress: Some(crate::types::AppPlanProgressSnapshot {
                turn_id: "turn-1".to_string(),
                explanation: Some("Ship plan mode".to_string()),
                plan: vec![crate::types::AppPlanStep {
                    step: "Build parser".to_string(),
                    status: crate::types::AppPlanStepStatus::InProgress,
                }],
            }),
            pending_plan_implementation_turn_id: Some("turn-1".to_string()),
        };
        let mut target = ThreadSnapshot::from_info("srv", make_thread_info("thread-1"));

        copy_thread_runtime_fields(&source, &mut target);

        assert_eq!(target.model.as_deref(), Some("gpt-5"));
        assert_eq!(target.collaboration_mode, AppModeKind::Plan);
        assert_eq!(target.reasoning_effort.as_deref(), Some("high"));
        assert_eq!(target.queued_follow_ups, source.queued_follow_ups);
        assert_eq!(target.active_turn_id, None);
        assert_eq!(target.context_tokens_used, Some(12_345));
        assert_eq!(target.model_context_window, Some(200_000));
        assert_eq!(
            target
                .rate_limits
                .as_ref()
                .and_then(|limits| limits.tokens_remaining),
            Some(20_000)
        );
        assert_eq!(target.realtime_session_id.as_deref(), Some("rt-1"));
        assert_eq!(target.active_plan_progress, source.active_plan_progress);
        assert_eq!(
            target.pending_plan_implementation_turn_id,
            source.pending_plan_implementation_turn_id
        );
    }

    #[test]
    fn copy_thread_runtime_fields_does_not_preserve_effective_permissions() {
        let source = ThreadSnapshot {
            key: ThreadKey {
                server_id: "srv".to_string(),
                thread_id: "thread-1".to_string(),
            },
            info: make_thread_info("thread-1"),
            collaboration_mode: AppModeKind::Default,
            model: None,
            reasoning_effort: None,
            effective_approval_policy: Some(crate::types::AppAskForApproval::Never),
            effective_sandbox_policy: Some(crate::types::AppSandboxPolicy::DangerFullAccess),
            items: Vec::new(),
            local_overlay_items: Vec::new(),
            queued_follow_ups: Vec::new(),
            queued_follow_up_drafts: Vec::new(),
            active_turn_id: None,
            context_tokens_used: None,
            model_context_window: None,
            rate_limits: None,
            realtime_session_id: None,
            active_plan_progress: None,
            pending_plan_implementation_turn_id: None,
        };
        let mut target = ThreadSnapshot::from_info("srv", make_thread_info("thread-1"));

        copy_thread_runtime_fields(&source, &mut target);

        assert_eq!(target.effective_approval_policy, None);
        assert_eq!(target.effective_sandbox_policy, None);
    }

    #[test]
    fn upsert_thread_snapshot_from_thread_read_response_uses_effective_permissions() {
        let reducer = AppStoreReducer::new();
        let response: upstream::ThreadReadResponse = serde_json::from_value(serde_json::json!({
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
            "approvalPolicy": "never",
            "sandbox": {
                "type": "dangerFullAccess"
            }
        }))
        .expect("thread/read response should deserialize");

        upsert_thread_snapshot_from_app_server_read_response(&reducer, "srv", response)
            .expect("upsert should succeed");

        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-1".to_string(),
        };
        let snapshot = reducer
            .snapshot()
            .threads
            .into_iter()
            .find_map(|(thread_key, thread)| (thread_key == key).then_some(thread))
            .expect("thread snapshot should exist");

        assert_eq!(
            snapshot.effective_approval_policy,
            Some(crate::types::AppAskForApproval::Never)
        );
        assert_eq!(
            snapshot.effective_sandbox_policy,
            Some(crate::types::AppSandboxPolicy::DangerFullAccess)
        );
    }

    #[test]
    fn remote_oauth_callback_port_reads_localhost_redirect() {
        let auth_url = "https://auth.openai.com/oauth/authorize?response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&state=abc";
        assert_eq!(remote_oauth_callback_port(auth_url).unwrap(), 1455);
    }

    #[test]
    fn approval_request_id_prefers_seed_type_for_local_responses() {
        let approval = PendingApproval {
            id: "42".to_string(),
            server_id: "srv".to_string(),
            kind: crate::types::ApprovalKind::Permissions,
            thread_id: Some("thread-1".to_string()),
            turn_id: Some("turn-1".to_string()),
            item_id: Some("item-1".to_string()),
            command: None,
            path: None,
            grant_root: None,
            cwd: None,
            reason: None,
        };
        let seed = PendingApprovalSeed {
            request_id: upstream::RequestId::Integer(42),
            raw_params: json!({}),
        };

        assert_eq!(
            server_request_id_json(approval_request_id(&approval, Some(&seed))),
            json!(42)
        );
    }

    #[test]
    fn approval_request_id_falls_back_to_string_for_non_numeric_ids() {
        let approval = PendingApproval {
            id: "req-42".to_string(),
            server_id: "srv".to_string(),
            kind: crate::types::ApprovalKind::Permissions,
            thread_id: Some("thread-1".to_string()),
            turn_id: Some("turn-1".to_string()),
            item_id: Some("item-1".to_string()),
            command: None,
            path: None,
            grant_root: None,
            cwd: None,
            reason: None,
        };

        assert_eq!(
            server_request_id_json(approval_request_id(&approval, None)),
            json!("req-42")
        );
    }

    #[test]
    fn websocket_stream_suppression_only_targets_stream_delta_events() {
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-1".to_string(),
        };
        let stream_events = [
            UiEvent::MessageDelta {
                key: key.clone(),
                item_id: "item-1".to_string(),
                delta: "a".to_string(),
            },
            UiEvent::ReasoningDelta {
                key: key.clone(),
                item_id: "item-2".to_string(),
                delta: "b".to_string(),
            },
            UiEvent::PlanDelta {
                key: key.clone(),
                item_id: "item-3".to_string(),
                delta: "c".to_string(),
            },
            UiEvent::CommandOutputDelta {
                key: key.clone(),
                item_id: "item-4".to_string(),
                delta: "d".to_string(),
            },
        ];
        for event in stream_events {
            assert!(should_suppress_websocket_stream_event(&event, true));
            assert!(!should_suppress_websocket_stream_event(&event, false));
        }

        let non_stream_event = UiEvent::TurnCompleted {
            key,
            turn_id: "turn-1".to_string(),
        };
        assert!(!should_suppress_websocket_stream_event(
            &non_stream_event,
            true
        ));
    }

    #[tokio::test]
    async fn store_listener_suppresses_websocket_stream_deltas_while_ipc_is_live() {
        let app_store = Arc::new(AppStoreReducer::new());
        let mut updates = app_store.subscribe();
        let sessions = Arc::new(RwLock::new(HashMap::new()));
        let server_id = "srv";
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: "thread-1".to_string(),
        };
        let config = make_server_config(server_id);
        app_store.upsert_server(&config, ServerHealthSnapshot::Connected, true);

        let connect_count = Arc::new(AtomicUsize::new(0));
        let reconnecting_ipc =
            make_reconnecting_ipc_client(Arc::clone(&connect_count), Duration::ZERO).await;
        wait_until(Duration::from_secs(1), || reconnecting_ipc.is_connected()).await;
        app_store.update_server_ipc_state(server_id, true);
        app_store.mark_server_ipc_primary(server_id);

        let session = Arc::new(ServerSession::test_stub(
            config.clone(),
            Some(reconnecting_ipc),
        ));
        sessions
            .write()
            .expect("sessions lock should not be poisoned")
            .insert(server_id.to_string(), session);

        let (event_tx, event_rx) = broadcast::channel(16);
        spawn_store_listener(Arc::clone(&app_store), Arc::clone(&sessions), event_rx);
        drain_app_updates(&mut updates);

        event_tx
            .send(UiEvent::MessageDelta {
                key: key.clone(),
                item_id: "assistant-1".to_string(),
                delta: "hello".to_string(),
            })
            .expect("send delta");
        sleep(Duration::from_millis(25)).await;
        let suppressed_updates = drain_app_updates(&mut updates);
        assert!(!suppressed_updates.iter().any(|update| matches!(
            update,
            AppStoreUpdateRecord::ThreadStreamingDelta { key: emitted_key, .. } if emitted_key == &key
        )));

        app_store.update_server_ipc_state(server_id, false);
        event_tx
            .send(UiEvent::MessageDelta {
                key: key.clone(),
                item_id: "assistant-1".to_string(),
                delta: "world".to_string(),
            })
            .expect("send fallback delta");
        wait_until(Duration::from_secs(1), || {
            drain_app_updates(&mut updates).iter().any(|update| {
                matches!(
                    update,
                    AppStoreUpdateRecord::ThreadStreamingDelta {
                        key: emitted_key,
                        item_id,
                        kind: ThreadStreamingDeltaKind::AssistantText,
                        text,
                    } if emitted_key == &key && item_id == "assistant-1" && text == "world"
                )
            })
        })
        .await;
    }

    #[tokio::test]
    async fn store_listener_uses_websocket_stream_deltas_after_server_failover_to_direct_only() {
        let app_store = Arc::new(AppStoreReducer::new());
        let mut updates = app_store.subscribe();
        let sessions = Arc::new(RwLock::new(HashMap::new()));
        let server_id = "srv";
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: "thread-1".to_string(),
        };
        let config = make_server_config(server_id);
        app_store.upsert_server(&config, ServerHealthSnapshot::Connected, true);

        let connect_count = Arc::new(AtomicUsize::new(0));
        let reconnecting_ipc =
            make_reconnecting_ipc_client(Arc::clone(&connect_count), Duration::ZERO).await;
        wait_until(Duration::from_secs(1), || reconnecting_ipc.is_connected()).await;
        app_store.update_server_ipc_state(server_id, true);
        app_store.mark_server_ipc_primary(server_id);

        let session = Arc::new(ServerSession::test_stub(
            config.clone(),
            Some(reconnecting_ipc),
        ));
        sessions
            .write()
            .expect("sessions lock should not be poisoned")
            .insert(server_id.to_string(), session);

        let (event_tx, event_rx) = broadcast::channel(16);
        spawn_store_listener(Arc::clone(&app_store), Arc::clone(&sessions), event_rx);
        drain_app_updates(&mut updates);

        app_store.fail_server_over_to_direct_only(
            server_id,
            IpcFailureClassification::FollowerCommandTimeoutWhileIpcHealthy,
        );

        event_tx
            .send(UiEvent::MessageDelta {
                key: key.clone(),
                item_id: "assistant-1".to_string(),
                delta: "after-failover".to_string(),
            })
            .expect("send post-failover delta");
        wait_until(Duration::from_secs(1), || {
            drain_app_updates(&mut updates).iter().any(|update| {
                matches!(
                    update,
                    AppStoreUpdateRecord::ThreadStreamingDelta {
                        key: emitted_key,
                        item_id,
                        kind: ThreadStreamingDeltaKind::AssistantText,
                        text,
                    } if emitted_key == &key && item_id == "assistant-1" && text == "after-failover"
                )
            })
        })
        .await;
    }

    #[tokio::test]
    async fn ipc_wrapper_invalidation_reconnects_with_new_client() {
        let connect_count = Arc::new(AtomicUsize::new(0));
        let reconnecting_ipc =
            make_reconnecting_ipc_client(Arc::clone(&connect_count), Duration::from_millis(40))
                .await;
        wait_until(Duration::from_secs(1), || reconnecting_ipc.is_connected()).await;
        let first_client_id = reconnecting_ipc
            .client()
            .expect("ipc client should be connected")
            .client_id()
            .to_string();

        reconnecting_ipc.invalidate();

        wait_until(Duration::from_secs(1), || {
            reconnecting_ipc
                .client()
                .is_some_and(|ipc_client| ipc_client.client_id() != first_client_id)
                && connect_count.load(Ordering::SeqCst) >= 2
        })
        .await;
        reconnecting_ipc.shutdown().await;
    }

    #[tokio::test]
    async fn ipc_connection_state_reader_seeds_store_from_current_connection_state() {
        let client = MobileClient::new();
        let server_id = "srv";
        let config = make_server_config(server_id);
        client
            .app_store
            .upsert_server(&config, ServerHealthSnapshot::Connected, true);

        let connect_count = Arc::new(AtomicUsize::new(0));
        let reconnecting_ipc =
            make_reconnecting_ipc_client(Arc::clone(&connect_count), Duration::ZERO).await;
        wait_until(Duration::from_secs(1), || reconnecting_ipc.is_connected()).await;

        let session = Arc::new(ServerSession::test_stub(
            config.clone(),
            Some(reconnecting_ipc),
        ));
        client
            .sessions
            .write()
            .expect("sessions lock should not be poisoned")
            .insert(server_id.to_string(), Arc::clone(&session));
        client.spawn_ipc_connection_state_reader(server_id.to_string(), Arc::clone(&session));

        wait_until(Duration::from_secs(1), || {
            client
                .app_store
                .snapshot()
                .servers
                .get(server_id)
                .is_some_and(|server| server.has_ipc)
        })
        .await;
    }

    #[tokio::test]
    async fn ipc_connection_state_reader_clears_store_after_invalidation() {
        let client = MobileClient::new();
        let server_id = "srv";
        let config = make_server_config(server_id);
        client
            .app_store
            .upsert_server(&config, ServerHealthSnapshot::Connected, true);

        let connect_count = Arc::new(AtomicUsize::new(0));
        let reconnecting_ipc =
            make_reconnecting_ipc_client(Arc::clone(&connect_count), Duration::from_millis(100))
                .await;
        wait_until(Duration::from_secs(1), || reconnecting_ipc.is_connected()).await;

        let session = Arc::new(ServerSession::test_stub(
            config.clone(),
            Some(reconnecting_ipc),
        ));
        client
            .sessions
            .write()
            .expect("sessions lock should not be poisoned")
            .insert(server_id.to_string(), Arc::clone(&session));
        client.spawn_ipc_connection_state_reader(server_id.to_string(), Arc::clone(&session));

        wait_until(Duration::from_secs(1), || {
            client
                .app_store
                .snapshot()
                .servers
                .get(server_id)
                .is_some_and(|server| server.has_ipc)
        })
        .await;

        session.invalidate_ipc();

        wait_until(Duration::from_secs(1), || {
            client
                .app_store
                .snapshot()
                .servers
                .get(server_id)
                .is_some_and(|server| !server.has_ipc)
        })
        .await;
    }

    #[tokio::test]
    async fn store_listener_resumes_websocket_stream_deltas_after_ipc_invalidation() {
        let client = MobileClient::new();
        let mut updates = client.app_store.subscribe();
        let sessions = Arc::new(RwLock::new(HashMap::new()));
        let server_id = "srv";
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: "thread-1".to_string(),
        };
        let config = make_server_config(server_id);
        client
            .app_store
            .upsert_server(&config, ServerHealthSnapshot::Connected, true);

        let connect_count = Arc::new(AtomicUsize::new(0));
        let reconnecting_ipc =
            make_reconnecting_ipc_client(Arc::clone(&connect_count), Duration::from_millis(100))
                .await;
        wait_until(Duration::from_secs(1), || reconnecting_ipc.is_connected()).await;
        let session = Arc::new(ServerSession::test_stub(
            config.clone(),
            Some(reconnecting_ipc),
        ));
        sessions
            .write()
            .expect("sessions lock should not be poisoned")
            .insert(server_id.to_string(), Arc::clone(&session));
        client
            .sessions
            .write()
            .expect("sessions lock should not be poisoned")
            .insert(server_id.to_string(), Arc::clone(&session));
        client.app_store.update_server_ipc_state(server_id, true);
        client.app_store.mark_server_ipc_primary(server_id);
        client.spawn_ipc_connection_state_reader(server_id.to_string(), Arc::clone(&session));

        let (event_tx, event_rx) = broadcast::channel(16);
        spawn_store_listener(
            Arc::clone(&client.app_store),
            Arc::clone(&sessions),
            event_rx,
        );
        drain_app_updates(&mut updates);

        event_tx
            .send(UiEvent::MessageDelta {
                key: key.clone(),
                item_id: "assistant-1".to_string(),
                delta: "suppressed".to_string(),
            })
            .expect("send suppressed delta");
        sleep(Duration::from_millis(25)).await;
        let suppressed_updates = drain_app_updates(&mut updates);
        assert!(!suppressed_updates.iter().any(|update| matches!(
            update,
            AppStoreUpdateRecord::ThreadStreamingDelta { key: emitted_key, .. } if emitted_key == &key
        )));

        session.invalidate_ipc();

        wait_until(Duration::from_secs(1), || {
            client
                .app_store
                .snapshot()
                .servers
                .get(server_id)
                .is_some_and(|server| !server.has_ipc)
        })
        .await;

        event_tx
            .send(UiEvent::MessageDelta {
                key: key.clone(),
                item_id: "assistant-1".to_string(),
                delta: "after-drop".to_string(),
            })
            .expect("send post-invalidation delta");
        wait_until(Duration::from_secs(1), || {
            drain_app_updates(&mut updates).iter().any(|update| {
                matches!(
                    update,
                    AppStoreUpdateRecord::ThreadStreamingDelta {
                        key: emitted_key,
                        item_id,
                        kind: ThreadStreamingDeltaKind::AssistantText,
                        text,
                    } if emitted_key == &key && item_id == "assistant-1" && text == "after-drop"
                )
            })
        })
        .await;
    }

    #[test]
    fn server_transport_requires_explicit_recovery_before_ipc_becomes_primary_again() {
        let app_store = AppStoreReducer::new();
        let server_id = "srv";
        let config = make_server_config(server_id);
        app_store.upsert_server(&config, ServerHealthSnapshot::Connected, true);

        app_store.update_server_ipc_state(server_id, true);
        app_store.mark_server_ipc_primary(server_id);
        let server = app_store
            .snapshot()
            .servers
            .get(server_id)
            .expect("server snapshot")
            .clone();
        assert_eq!(
            server.transport.authority,
            ServerTransportAuthority::IpcPrimary
        );
        assert!(server.has_ipc);

        app_store.fail_server_over_to_direct_only(
            server_id,
            IpcFailureClassification::FollowerCommandTimeoutWhileIpcHealthy,
        );
        app_store.update_server_ipc_state(server_id, true);

        let server = app_store
            .snapshot()
            .servers
            .get(server_id)
            .expect("server snapshot")
            .clone();
        assert_eq!(
            server.transport.authority,
            ServerTransportAuthority::DirectOnly
        );
        assert!(!server.has_ipc);

        app_store.mark_server_ipc_recovering(server_id);
        app_store.update_server_ipc_state(server_id, true);

        let server = app_store
            .snapshot()
            .servers
            .get(server_id)
            .expect("server snapshot")
            .clone();
        assert_eq!(
            server.transport.authority,
            ServerTransportAuthority::IpcPrimary
        );
        assert!(server.has_ipc);
    }

    #[tokio::test]
    async fn stale_ipc_start_turn_falls_back_to_direct_only_once_per_server() {
        let client = MobileClient::new();
        let server_id = "srv";
        let thread_id = "thread-1";
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };
        let config = make_server_config(server_id);
        client
            .app_store
            .upsert_server(&config, ServerHealthSnapshot::Connected, true);
        client.app_store.update_server_ipc_state(server_id, true);
        client.app_store.mark_server_ipc_primary(server_id);
        let mut thread = ThreadSnapshot::from_info(server_id, make_thread_info(thread_id));
        thread.info.status = ThreadSummaryStatus::Idle;
        client.app_store.upsert_thread_snapshot(thread);

        let connect_count = Arc::new(AtomicUsize::new(0));
        let reconnecting_ipc = make_error_reconnecting_ipc_client(
            Arc::clone(&connect_count),
            Duration::from_millis(20),
            "no-client-found",
        )
        .await;
        wait_until(Duration::from_secs(1), || reconnecting_ipc.is_connected()).await;

        let turn_start_calls = Arc::new(StdMutex::new(Vec::<upstream::ClientRequest>::new()));
        let request_handler: TestRequestHandler = {
            let turn_start_calls = Arc::clone(&turn_start_calls);
            Arc::new(move |request| {
                turn_start_calls
                    .lock()
                    .expect("turn start calls lock should not be poisoned")
                    .push(request.clone());
                match request {
                    upstream::ClientRequest::TurnStart { .. } => {
                        serde_json::to_value(upstream::TurnStartResponse {
                            turn: upstream::Turn {
                                id: "turn-next".to_string(),
                                items: Vec::new(),
                                status: upstream::TurnStatus::InProgress,
                                error: None,
                            },
                        })
                        .map_err(|error| RpcError::Deserialization(error.to_string()))
                    }
                    other => Err(RpcError::Deserialization(format!(
                        "unexpected request in test: {}",
                        other.method()
                    ))),
                }
            })
        };
        let session = Arc::new(ServerSession::test_stub_with_handlers(
            config,
            Some(reconnecting_ipc),
            Some(request_handler),
            None,
            None,
        ));
        client
            .sessions
            .write()
            .expect("sessions lock should not be poisoned")
            .insert(server_id.to_string(), Arc::clone(&session));

        client
            .start_turn(
                server_id,
                upstream::TurnStartParams {
                    thread_id: thread_id.to_string(),
                    input: vec![upstream::UserInput::Text {
                        text: "hello".to_string(),
                        text_elements: Vec::new(),
                    }],
                    cwd: None,
                    approval_policy: None,
                    approvals_reviewer: None,
                    sandbox_policy: None,
                    model: None,
                    service_tier: None,
                    effort: None,
                    summary: None,
                    personality: None,
                    output_schema: None,
                    collaboration_mode: None,
                },
            )
            .await
            .expect("start turn should succeed");

        let captured = turn_start_calls
            .lock()
            .expect("turn start calls lock should not be poisoned");
        assert_eq!(captured.len(), 1);
        drop(captured);

        let server = client
            .app_store
            .snapshot()
            .servers
            .get(server_id)
            .expect("server snapshot")
            .clone();
        assert_eq!(
            server.transport.authority,
            ServerTransportAuthority::DirectOnly
        );
        assert!(!server.has_ipc);

        let thread = client.snapshot_thread(&key).expect("thread snapshot");
        // The overlay is created before the IPC attempt and stays after
        // the fallback direct turn/start succeeds and binds it.
        assert_eq!(thread.local_overlay_items.len(), 1);
        assert!(
            thread.local_overlay_items[0]
                .id
                .starts_with("local-user-message:")
        );
    }

    #[tokio::test]
    async fn timed_out_ipc_start_turn_falls_back_to_direct_without_server_failover() {
        let client = MobileClient::new();
        let server_id = "srv";
        let thread_id = "thread-1";
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };
        let config = make_server_config(server_id);
        client
            .app_store
            .upsert_server(&config, ServerHealthSnapshot::Connected, true);
        client.app_store.update_server_ipc_state(server_id, true);
        client.app_store.mark_server_ipc_primary(server_id);
        let mut thread = ThreadSnapshot::from_info(server_id, make_thread_info(thread_id));
        thread.info.status = ThreadSummaryStatus::Idle;
        client.app_store.upsert_thread_snapshot(thread);

        let connect_count = Arc::new(AtomicUsize::new(0));
        let reconnecting_ipc = make_error_reconnecting_ipc_client(
            Arc::clone(&connect_count),
            Duration::from_millis(20),
            "request-timeout",
        )
        .await;
        wait_until(Duration::from_secs(1), || reconnecting_ipc.is_connected()).await;

        let turn_start_calls = Arc::new(StdMutex::new(Vec::<upstream::ClientRequest>::new()));
        let request_handler: TestRequestHandler = {
            let turn_start_calls = Arc::clone(&turn_start_calls);
            Arc::new(move |request| {
                turn_start_calls
                    .lock()
                    .expect("turn start calls lock should not be poisoned")
                    .push(request.clone());
                match request {
                    upstream::ClientRequest::TurnStart { .. } => {
                        serde_json::to_value(upstream::TurnStartResponse {
                            turn: upstream::Turn {
                                id: "turn-timeout-fallback".to_string(),
                                items: Vec::new(),
                                status: upstream::TurnStatus::InProgress,
                                error: None,
                            },
                        })
                        .map_err(|error| RpcError::Deserialization(error.to_string()))
                    }
                    other => Err(RpcError::Deserialization(format!(
                        "unexpected request in test: {}",
                        other.method()
                    ))),
                }
            })
        };
        let session = Arc::new(ServerSession::test_stub_with_handlers(
            config,
            Some(reconnecting_ipc),
            Some(request_handler),
            None,
            None,
        ));
        client
            .sessions
            .write()
            .expect("sessions lock should not be poisoned")
            .insert(server_id.to_string(), Arc::clone(&session));

        client
            .start_turn(
                server_id,
                upstream::TurnStartParams {
                    thread_id: thread_id.to_string(),
                    input: vec![upstream::UserInput::Text {
                        text: "hello".to_string(),
                        text_elements: Vec::new(),
                    }],
                    cwd: None,
                    approval_policy: None,
                    approvals_reviewer: None,
                    sandbox_policy: None,
                    model: None,
                    service_tier: None,
                    effort: None,
                    summary: None,
                    personality: None,
                    output_schema: None,
                    collaboration_mode: None,
                },
            )
            .await
            .expect("start turn should succeed");

        let captured = turn_start_calls
            .lock()
            .expect("turn start calls lock should not be poisoned");
        assert_eq!(captured.len(), 1);
        drop(captured);

        let server = client
            .app_store
            .snapshot()
            .servers
            .get(server_id)
            .expect("server snapshot")
            .clone();
        assert_eq!(
            server.transport.authority,
            ServerTransportAuthority::IpcPrimary
        );
        assert!(server.has_ipc);

        let thread = client.snapshot_thread(&key).expect("thread snapshot");
        // The overlay is created before the IPC attempt and stays after
        // the fallback direct turn/start succeeds and binds it.
        assert_eq!(thread.local_overlay_items.len(), 1);
        assert!(
            thread.local_overlay_items[0]
                .id
                .starts_with("local-user-message:")
        );
    }

    #[tokio::test]
    async fn stale_ipc_steer_queued_follow_up_falls_back_to_turn_steer() {
        let client = MobileClient::new();
        let server_id = "srv";
        let thread_id = "thread-1";
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };
        let config = make_server_config(server_id);
        client
            .app_store
            .upsert_server(&config, ServerHealthSnapshot::Connected, true);
        client.app_store.update_server_ipc_state(server_id, true);
        client.app_store.mark_server_ipc_primary(server_id);

        let mut thread = thread_snapshot_with_active_turn(server_id, thread_id, "turn-active");
        let draft = queued_follow_up_draft_from_inputs(
            &[upstream::UserInput::Text {
                text: "follow up".to_string(),
                text_elements: Vec::new(),
            }],
            AppQueuedFollowUpKind::Message,
        )
        .expect("draft");
        let preview_id = draft.preview.id.clone();
        thread.queued_follow_up_drafts.push(draft);
        client.app_store.upsert_thread_snapshot(thread);

        let connect_count = Arc::new(AtomicUsize::new(0));
        let reconnecting_ipc = make_error_reconnecting_ipc_client(
            Arc::clone(&connect_count),
            Duration::from_millis(20),
            "no-client-found",
        )
        .await;
        wait_until(Duration::from_secs(1), || reconnecting_ipc.is_connected()).await;

        let steer_calls = Arc::new(StdMutex::new(Vec::<upstream::ClientRequest>::new()));
        let request_handler: TestRequestHandler = {
            let steer_calls = Arc::clone(&steer_calls);
            Arc::new(move |request| {
                let request_for_log = request.clone();
                steer_calls
                    .lock()
                    .expect("steer calls lock should not be poisoned")
                    .push(request_for_log);
                match request {
                    upstream::ClientRequest::TurnSteer { .. } => {
                        Ok(json!({ "turnId": "turn-next" }))
                    }
                    other => Err(RpcError::Deserialization(format!(
                        "unexpected request in test: {}",
                        other.method()
                    ))),
                }
            })
        };
        let session = Arc::new(ServerSession::test_stub_with_handlers(
            config,
            Some(reconnecting_ipc),
            Some(request_handler),
            None,
            None,
        ));
        client
            .sessions
            .write()
            .expect("sessions lock should not be poisoned")
            .insert(server_id.to_string(), Arc::clone(&session));

        client
            .steer_queued_follow_up(&key, &preview_id)
            .await
            .expect("steer should succeed");

        let captured = steer_calls
            .lock()
            .expect("steer calls lock should not be poisoned");
        assert_eq!(captured.len(), 1);
        assert!(matches!(
            &captured[0],
            upstream::ClientRequest::TurnSteer { params, .. }
                if params.thread_id == thread_id && params.expected_turn_id == "turn-active"
        ));
        drop(captured);

        let thread = client.snapshot_thread(&key).expect("thread snapshot");
        assert!(
            thread
                .queued_follow_up_drafts
                .iter()
                .all(|d| d.preview.kind == AppQueuedFollowUpKind::PendingSteer)
        );
        let server = client
            .app_store
            .snapshot()
            .servers
            .get(server_id)
            .expect("server snapshot")
            .clone();
        assert!(!server.has_ipc);
        assert_eq!(
            server.transport.authority,
            ServerTransportAuthority::DirectOnly
        );
    }

    #[tokio::test]
    async fn stale_ipc_delete_queued_follow_up_updates_local_state_and_reconnects() {
        let client = MobileClient::new();
        let server_id = "srv";
        let thread_id = "thread-1";
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };
        let config = make_server_config(server_id);
        client
            .app_store
            .upsert_server(&config, ServerHealthSnapshot::Connected, true);
        client.app_store.update_server_ipc_state(server_id, true);
        client.app_store.mark_server_ipc_primary(server_id);

        let mut thread = thread_snapshot_with_active_turn(server_id, thread_id, "turn-active");
        let first = queued_follow_up_draft_from_inputs(
            &[upstream::UserInput::Text {
                text: "first".to_string(),
                text_elements: Vec::new(),
            }],
            AppQueuedFollowUpKind::Message,
        )
        .expect("first draft");
        let second = queued_follow_up_draft_from_inputs(
            &[upstream::UserInput::Text {
                text: "second".to_string(),
                text_elements: Vec::new(),
            }],
            AppQueuedFollowUpKind::Message,
        )
        .expect("second draft");
        let delete_id = first.preview.id.clone();
        let keep_id = second.preview.id.clone();
        thread.queued_follow_up_drafts.extend([first, second]);
        client.app_store.upsert_thread_snapshot(thread);

        let connect_count = Arc::new(AtomicUsize::new(0));
        let reconnecting_ipc = make_error_reconnecting_ipc_client(
            Arc::clone(&connect_count),
            Duration::from_millis(20),
            "no-client-found",
        )
        .await;
        wait_until(Duration::from_secs(1), || reconnecting_ipc.is_connected()).await;
        let session = Arc::new(ServerSession::test_stub(config, Some(reconnecting_ipc)));
        client
            .sessions
            .write()
            .expect("sessions lock should not be poisoned")
            .insert(server_id.to_string(), session);

        client
            .delete_queued_follow_up(&key, &delete_id)
            .await
            .expect("delete should succeed");

        let thread = client.snapshot_thread(&key).expect("thread snapshot");
        assert_eq!(thread.queued_follow_up_drafts.len(), 1);
        assert_eq!(thread.queued_follow_up_drafts[0].preview.id, keep_id);
        let server = client
            .app_store
            .snapshot()
            .servers
            .get(server_id)
            .expect("server snapshot")
            .clone();
        assert!(!server.has_ipc);
        assert_eq!(
            server.transport.authority,
            ServerTransportAuthority::DirectOnly
        );
    }

    #[tokio::test]
    async fn stale_ipc_approval_response_falls_back_to_server_request_resolution() {
        let client = MobileClient::new();
        let server_id = "srv";
        let thread_id = "thread-1";
        let config = make_server_config(server_id);
        client
            .app_store
            .upsert_server(&config, ServerHealthSnapshot::Connected, true);
        client.app_store.update_server_ipc_state(server_id, true);
        client.app_store.mark_server_ipc_primary(server_id);

        let approval = PendingApproval {
            id: "approval-1".to_string(),
            server_id: server_id.to_string(),
            kind: crate::types::ApprovalKind::Command,
            thread_id: Some(thread_id.to_string()),
            turn_id: Some("turn-1".to_string()),
            item_id: Some("item-1".to_string()),
            command: Some("ls".to_string()),
            path: None,
            grant_root: None,
            cwd: Some("/repo".to_string()),
            reason: None,
        };
        client
            .app_store
            .replace_pending_approvals_with_seeds(vec![PendingApprovalWithSeed {
                approval: approval.clone(),
                seed: PendingApprovalSeed {
                    request_id: upstream::RequestId::Integer(42),
                    raw_params: json!({}),
                },
            }]);

        let connect_count = Arc::new(AtomicUsize::new(0));
        let reconnecting_ipc = make_error_reconnecting_ipc_client(
            Arc::clone(&connect_count),
            Duration::from_millis(20),
            "no-client-found",
        )
        .await;
        wait_until(Duration::from_secs(1), || reconnecting_ipc.is_connected()).await;

        let resolved = Arc::new(StdMutex::new(
            Vec::<(upstream::RequestId, serde_json::Value)>::new(),
        ));
        let resolve_handler: TestResolveHandler = {
            let resolved = Arc::clone(&resolved);
            Arc::new(move |request_id, result| {
                resolved
                    .lock()
                    .expect("resolved approvals lock should not be poisoned")
                    .push((
                        request_id,
                        serde_json::to_value(result).expect("jsonrpc result"),
                    ));
                Ok(())
            })
        };
        let session = Arc::new(ServerSession::test_stub_with_handlers(
            config,
            Some(reconnecting_ipc),
            None,
            Some(resolve_handler),
            None,
        ));
        client
            .sessions
            .write()
            .expect("sessions lock should not be poisoned")
            .insert(server_id.to_string(), session);

        client
            .respond_to_approval("approval-1", ApprovalDecisionValue::Accept)
            .await
            .expect("approval response should succeed");

        let resolved = resolved
            .lock()
            .expect("resolved approvals lock should not be poisoned");
        assert_eq!(resolved.len(), 1);
        assert!(matches!(&resolved[0].0, upstream::RequestId::Integer(42)));
        drop(resolved);
        assert!(client.app_store.snapshot().pending_approvals.is_empty());
        let server = client
            .app_store
            .snapshot()
            .servers
            .get(server_id)
            .expect("server snapshot")
            .clone();
        assert_eq!(
            server.transport.authority,
            ServerTransportAuthority::DirectOnly
        );
        assert!(!server.has_ipc);
    }

    #[tokio::test]
    async fn stale_ipc_user_input_response_falls_back_to_server_request_resolution() {
        let client = MobileClient::new();
        let server_id = "srv";
        let thread_id = "thread-1";
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };
        let config = make_server_config(server_id);
        client
            .app_store
            .upsert_server(&config, ServerHealthSnapshot::Connected, true);
        client.app_store.update_server_ipc_state(server_id, true);
        client.app_store.mark_server_ipc_primary(server_id);
        client
            .app_store
            .upsert_thread_snapshot(ThreadSnapshot::from_info(
                server_id,
                make_thread_info(thread_id),
            ));

        let question = PendingUserInputQuestion {
            id: "question-1".to_string(),
            header: Some("Pick".to_string()),
            question: "Pick one".to_string(),
            is_other_allowed: false,
            is_secret: false,
            options: vec![PendingUserInputOption {
                label: "One".to_string(),
                description: None,
            }],
        };
        let mut request = make_user_input_request(question);
        request.thread_id = thread_id.to_string();
        client.app_store.replace_pending_user_inputs(vec![request]);

        let connect_count = Arc::new(AtomicUsize::new(0));
        let reconnecting_ipc = make_error_reconnecting_ipc_client(
            Arc::clone(&connect_count),
            Duration::from_millis(20),
            "no-client-found",
        )
        .await;
        wait_until(Duration::from_secs(1), || reconnecting_ipc.is_connected()).await;

        let resolved = Arc::new(StdMutex::new(
            Vec::<(upstream::RequestId, serde_json::Value)>::new(),
        ));
        let resolve_handler: TestResolveHandler = {
            let resolved = Arc::clone(&resolved);
            Arc::new(move |request_id, result| {
                resolved
                    .lock()
                    .expect("resolved user inputs lock should not be poisoned")
                    .push((
                        request_id,
                        serde_json::to_value(result).expect("jsonrpc result"),
                    ));
                Ok(())
            })
        };
        let session = Arc::new(ServerSession::test_stub_with_handlers(
            config,
            Some(reconnecting_ipc),
            None,
            Some(resolve_handler),
            None,
        ));
        client
            .sessions
            .write()
            .expect("sessions lock should not be poisoned")
            .insert(server_id.to_string(), session);

        client
            .respond_to_user_input(
                "req-1",
                vec![PendingUserInputAnswer {
                    question_id: "question-1".to_string(),
                    answers: vec!["opt-1".to_string()],
                }],
            )
            .await
            .expect("user input response should succeed");

        let resolved = resolved
            .lock()
            .expect("resolved user inputs lock should not be poisoned");
        assert_eq!(resolved.len(), 1);
        assert!(matches!(
            &resolved[0].0,
            upstream::RequestId::String(id) if id == "req-1"
        ));
        drop(resolved);
        assert!(client.app_store.snapshot().pending_user_inputs.is_empty());
        let thread = client.snapshot_thread(&key).expect("thread snapshot");
        assert!(matches!(
            thread
                .local_overlay_items
                .iter()
                .find(|item| item.id == "user-input-response:req-1"),
            Some(item)
                if matches!(
                    item.content,
                    HydratedConversationItemContent::UserInputResponse(_)
                )
        ));
        let server = client
            .app_store
            .snapshot()
            .servers
            .get(server_id)
            .expect("server snapshot")
            .clone();
        assert_eq!(
            server.transport.authority,
            ServerTransportAuthority::DirectOnly
        );
        assert!(!server.has_ipc);
    }

    #[test]
    fn thread_projection_restores_queued_follow_up_previews_from_input_state() {
        let projection = thread_projection_from_conversation_json(
            "srv",
            "thread-1",
            &json!({
                "title": "IPC Thread",
                "cwd": "/repo",
                "rolloutPath": "/repo/.codex/session.jsonl",
                "createdAt": 1710000000000i64,
                "updatedAt": 1710000005000i64,
                "threadRuntimeStatus": { "type": "active", "activeFlags": [] },
                "source": "vscode",
                "turns": [],
                "requests": [],
                "inputState": {
                    "pendingSteers": [
                        { "text": "Please continue." }
                    ],
                    "rejectedSteersQueue": [
                        { "text": "Try again after the tool call." }
                    ],
                    "queuedUserMessages": [
                        { "text": "Queued follow-up" }
                    ]
                }
            }),
        )
        .expect("thread projection should succeed");

        assert_eq!(
            projection
                .snapshot
                .queued_follow_ups
                .iter()
                .map(|preview| (preview.kind, preview.text.as_str()))
                .collect::<Vec<_>>(),
            vec![
                (AppQueuedFollowUpKind::PendingSteer, "Please continue."),
                (
                    AppQueuedFollowUpKind::RetryingSteer,
                    "Try again after the tool call.",
                ),
                (AppQueuedFollowUpKind::Message, "Queued follow-up"),
            ]
        );
    }

    #[test]
    fn queued_followups_broadcast_payload_supports_text_and_attachment_only_messages() {
        let drafts = queued_follow_up_drafts_from_message_values(&[
            json!("Queued follow-up"),
            json!({
                "kind": "pending_steer",
                "text": "Please continue."
            }),
            json!({
                "kind": "rejected_steer",
                "localImages": [{}],
                "remoteImageUrls": ["https://example.com/image.png"]
            }),
        ]);

        assert_eq!(
            drafts
                .iter()
                .map(|draft| (draft.preview.kind, draft.preview.text.as_str()))
                .collect::<Vec<_>>(),
            vec![
                (AppQueuedFollowUpKind::Message, "Queued follow-up"),
                (AppQueuedFollowUpKind::PendingSteer, "Please continue."),
                (AppQueuedFollowUpKind::RetryingSteer, "2 image attachments",),
            ]
        );
    }

    #[test]
    fn queued_follow_up_message_json_round_trips_skill_inputs() {
        let inputs = vec![
            upstream::UserInput::Text {
                text: "Use the repo skill here.".to_string(),
                text_elements: Vec::new(),
            },
            upstream::UserInput::Skill {
                name: "repo-helper".to_string(),
                path: PathBuf::from("/tmp/repo-helper/SKILL.md"),
            },
        ];

        let message_json = queued_follow_up_message_json_from_inputs(&inputs)
            .expect("queued message json should serialize");
        let round_trip_inputs = queued_follow_up_inputs_from_json_value(&message_json);

        assert_eq!(round_trip_inputs, inputs);
    }

    #[test]
    fn queued_follow_up_preview_from_inputs_can_mark_pending_steers() {
        let preview = queued_follow_up_preview_from_inputs(
            &[upstream::UserInput::Text {
                text: "Please try the same search again.".to_string(),
                text_elements: Vec::new(),
            }],
            AppQueuedFollowUpKind::PendingSteer,
        )
        .expect("preview should be generated");

        assert_eq!(preview.kind, AppQueuedFollowUpKind::PendingSteer);
        assert_eq!(preview.text, "Please try the same search again.");
    }

    #[test]
    fn ipc_no_client_found_clears_server_ipc_state() {
        let error = IpcError::Request(RequestError::NoClientFound);
        assert!(ipc_command_error_clears_server_ipc_state(&error));
    }

    #[test]
    fn ipc_client_disconnected_clears_server_ipc_state() {
        let error = IpcError::Request(RequestError::ClientDisconnected);
        assert!(ipc_command_error_clears_server_ipc_state(&error));
    }
}
