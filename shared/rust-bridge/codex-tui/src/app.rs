use std::sync::Arc;
use std::time::{Duration, Instant};

use crossterm::event::{Event, KeyCode, KeyEvent, KeyModifiers, MouseEvent, MouseEventKind};
use futures::StreamExt;
use ratatui::{
    Frame,
    layout::{Constraint, Layout},
};
use tokio::sync::{broadcast, mpsc};

use codex_app_server_protocol as upstream;
use codex_mobile_client::MobileClient;
use codex_mobile_client::store::{AppSnapshot, AppUpdate};
use codex_mobile_client::types::{ApprovalDecisionValue, ThreadKey};

use crate::input::InputMode;
use crate::router::{ConfirmAction, Overlay, Router, Screen};
use crate::screens::{conversation, discovery, home, sessions, settings};
use crate::widgets::{approval_bar, phone_frame, status_bar, user_input_bar};

/// Messages from background tasks back to the main loop.
enum BgMessage {
    DiscoveryScanDone(Vec<discovery::DiscoveredServerEntry>),
    ThreadStarted(ThreadKey),
    ServerConnected,
    StatusMessage(String),
}

pub struct App {
    pub client: Arc<MobileClient>,
    pub snapshot: AppSnapshot,
    pub update_rx: broadcast::Receiver<AppUpdate>,
    pub router: Router,
    pub mode: InputMode,
    pub status_message: Option<(String, Instant)>,
    pub should_quit: bool,
    pub user_input_text: String,
    bg_tx: mpsc::UnboundedSender<BgMessage>,
    bg_rx: mpsc::UnboundedReceiver<BgMessage>,
}

impl App {
    pub fn new(client: Arc<MobileClient>) -> Self {
        let snapshot = client.app_snapshot();
        let update_rx = client.subscribe_app_updates();
        let (bg_tx, bg_rx) = mpsc::unbounded_channel();
        Self {
            client,
            snapshot,
            update_rx,
            router: Router::new(),
            mode: InputMode::Normal,
            status_message: None,
            should_quit: false,
            user_input_text: String::new(),
            bg_tx,
            bg_rx,
        }
    }

    pub async fn run(
        &mut self,
        terminal: &mut ratatui::Terminal<impl ratatui::backend::Backend>,
    ) -> anyhow::Result<()> {
        let tick_rate = Duration::from_millis(100);
        let mut event_stream = crossterm::event::EventStream::new();

        loop {
            terminal.draw(|frame| self.render(frame))?;

            tokio::select! {
                Some(Ok(evt)) = event_stream.next() => {
                    self.handle_terminal_event(evt).await;
                }
                result = self.update_rx.recv() => {
                    match result {
                        Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {
                            self.snapshot = self.client.app_snapshot();
                        }
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                }
                Some(msg) = self.bg_rx.recv() => {
                    self.handle_bg_message(msg);
                }
                _ = tokio::time::sleep(tick_rate) => {
                    self.tick();
                }
            }

            if self.should_quit {
                break;
            }
        }
        Ok(())
    }

    fn tick(&mut self) {
        if let Some((_, when)) = &self.status_message {
            if when.elapsed() > Duration::from_secs(5) {
                self.status_message = None;
            }
        }
    }

    // ── Rendering ────────────────────────────────────────────────────

    fn render(&mut self, frame: &mut Frame) {
        // Render phone bezel and get the inner content area
        let content_area = phone_frame::render_frame(frame);

        // Split content into screen area + status bar
        let chunks =
            Layout::vertical([Constraint::Min(1), Constraint::Length(1)]).split(content_area);

        // Current screen
        match self.router.current_mut() {
            Screen::Home(state) => home::render(frame, chunks[0], state, &self.snapshot),
            Screen::Sessions(state) => sessions::render(frame, chunks[0], state, &self.snapshot),
            Screen::Conversation(state) => {
                let insert = self.mode == InputMode::Insert;
                conversation::render(frame, chunks[0], state, &self.snapshot, insert);

                // Approval bar overlay at bottom of messages area
                if let Some(approval) = self.active_thread_approval() {
                    let bar_area = ratatui::layout::Rect {
                        x: chunks[0].x,
                        y: chunks[0].bottom().saturating_sub(4),
                        width: chunks[0].width,
                        height: 1,
                    };
                    approval_bar::render(frame, bar_area, &approval);
                }

                // User input prompt overlay
                if let Some(request) = self.active_thread_user_input() {
                    let bar_area = ratatui::layout::Rect {
                        x: chunks[0].x,
                        y: chunks[0].bottom().saturating_sub(5),
                        width: chunks[0].width,
                        height: 2,
                    };
                    user_input_bar::render(frame, bar_area, &request, &self.user_input_text);
                }
            }
        }

        // Overlays render within the phone frame too
        match &mut self.router.overlay {
            Some(Overlay::Discovery(state)) => discovery::render(frame, content_area, state),
            Some(Overlay::Settings(state)) => {
                settings::render(frame, content_area, state, &self.snapshot);
            }
            Some(Overlay::Confirm { message, .. }) => {
                use crate::widgets::popup;
                use ratatui::widgets::{Block, Borders, Clear, Paragraph};
                let popup_area = popup::centered_rect(80, 30, content_area);
                frame.render_widget(Clear, popup_area);
                let block = Block::default()
                    .title(" Confirm ")
                    .borders(Borders::ALL)
                    .border_style(crate::theme::border_focused());
                let inner = block.inner(popup_area);
                frame.render_widget(block, popup_area);
                frame.render_widget(Paragraph::new(format!("{message}\n\n[y]es / [n]o")), inner);
            }
            None => {}
        }

        // Status bar at bottom of phone
        let status_msg = self.status_message.as_ref().map(|(msg, _)| msg.as_str());
        status_bar::render(frame, chunks[1], &self.snapshot, self.mode, status_msg);
    }

    // ── Event dispatch ───────────────────────────────────────────────

    async fn handle_terminal_event(&mut self, evt: Event) {
        match evt {
            Event::Key(key) => self.handle_key(key).await,
            Event::Mouse(mouse) => self.handle_mouse(mouse),
            Event::Resize(_, _) => {}
            _ => {}
        }
    }

    fn handle_mouse(&mut self, mouse: MouseEvent) {
        match mouse.kind {
            MouseEventKind::ScrollDown => {
                if let Screen::Conversation(state) = self.router.current_mut() {
                    state.auto_scroll = false;
                    state.scroll_offset = state.scroll_offset.saturating_add(3);
                }
            }
            MouseEventKind::ScrollUp => {
                if let Screen::Conversation(state) = self.router.current_mut() {
                    state.auto_scroll = false;
                    state.scroll_offset = state.scroll_offset.saturating_sub(3);
                }
            }
            _ => {}
        }
    }

    async fn handle_key(&mut self, key: KeyEvent) {
        // Global quit
        if key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('q') {
            self.should_quit = true;
            return;
        }

        // Overlay keys first
        if self.router.has_overlay() {
            self.handle_overlay_key(key).await;
            return;
        }

        // Check if user input prompt is active
        if self.active_thread_user_input().is_some() {
            self.handle_user_input_key(key).await;
            return;
        }

        match self.mode {
            InputMode::Normal => self.handle_normal_key(key).await,
            InputMode::Insert => self.handle_insert_key(key).await,
            InputMode::Search => self.handle_search_key(key).await,
        }
    }

    // ── Overlay keys ─────────────────────────────────────────────────

    async fn handle_overlay_key(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::Esc => self.router.close_overlay(),

            // Confirm dialog
            KeyCode::Char('y') if matches!(self.router.overlay, Some(Overlay::Confirm { .. })) => {
                if let Some(Overlay::Confirm { action, .. }) = &self.router.overlay {
                    let action = action.clone();
                    self.execute_confirm_action(action).await;
                }
                self.router.close_overlay();
            }
            KeyCode::Char('n') if matches!(self.router.overlay, Some(Overlay::Confirm { .. })) => {
                self.router.close_overlay();
            }

            // Discovery navigation
            KeyCode::Char('j') | KeyCode::Down => {
                if let Some(Overlay::Discovery(state)) = &mut self.router.overlay {
                    if state.focus == discovery::DiscoveryFocus::ServerList {
                        let len = state.servers.len();
                        if len > 0 {
                            let i = state
                                .list_state
                                .selected()
                                .map(|i| (i + 1) % len)
                                .unwrap_or(0);
                            state.list_state.select(Some(i));
                        }
                    }
                } else if let Some(Overlay::Settings(state)) = &mut self.router.overlay {
                    let i = state.list_state.selected().unwrap_or(0);
                    state.list_state.select(Some(i + 1));
                }
            }
            KeyCode::Char('k') | KeyCode::Up => {
                if let Some(Overlay::Discovery(state)) = &mut self.router.overlay {
                    if state.focus == discovery::DiscoveryFocus::ServerList {
                        let len = state.servers.len();
                        if len > 0 {
                            let i = state
                                .list_state
                                .selected()
                                .map(|i| if i == 0 { len - 1 } else { i - 1 })
                                .unwrap_or(0);
                            state.list_state.select(Some(i));
                        }
                    }
                } else if let Some(Overlay::Settings(state)) = &mut self.router.overlay {
                    let i = state.list_state.selected().unwrap_or(1);
                    state.list_state.select(Some(i.saturating_sub(1)));
                }
            }

            // Discovery actions
            KeyCode::Enter => {
                if matches!(self.router.overlay, Some(Overlay::Discovery(_))) {
                    self.connect_from_discovery();
                }
            }
            KeyCode::Tab => {
                if let Some(Overlay::Discovery(state)) = &mut self.router.overlay {
                    state.focus = match state.focus {
                        discovery::DiscoveryFocus::ServerList => {
                            discovery::DiscoveryFocus::ManualHost
                        }
                        discovery::DiscoveryFocus::ManualHost => {
                            discovery::DiscoveryFocus::ManualPort
                        }
                        discovery::DiscoveryFocus::ManualPort => {
                            discovery::DiscoveryFocus::ServerList
                        }
                    };
                }
            }
            KeyCode::Char('r') => {
                if matches!(self.router.overlay, Some(Overlay::Discovery(_))) {
                    self.run_discovery_scan();
                }
            }

            // Text input for discovery manual fields
            KeyCode::Char(c) => {
                if let Some(Overlay::Discovery(state)) = &mut self.router.overlay {
                    match state.focus {
                        discovery::DiscoveryFocus::ManualHost => state.manual_host.push(c),
                        discovery::DiscoveryFocus::ManualPort => {
                            if c.is_ascii_digit() {
                                state.manual_port.push(c);
                            }
                        }
                        _ => {}
                    }
                }
            }
            KeyCode::Backspace => {
                if let Some(Overlay::Discovery(state)) = &mut self.router.overlay {
                    match state.focus {
                        discovery::DiscoveryFocus::ManualHost => {
                            state.manual_host.pop();
                        }
                        discovery::DiscoveryFocus::ManualPort => {
                            state.manual_port.pop();
                        }
                        _ => {}
                    }
                }
            }

            _ => {}
        }
    }

    // ── Normal mode keys ─────────────────────────────────────────────

    async fn handle_normal_key(&mut self, key: KeyEvent) {
        match self.router.current() {
            Screen::Home(_) => self.handle_home_key(key).await,
            Screen::Sessions(_) => self.handle_sessions_key(key).await,
            Screen::Conversation(_) => self.handle_conversation_key(key).await,
        }
    }

    async fn handle_home_key(&mut self, key: KeyEvent) {
        let Screen::Home(_) = self.router.current_mut() else {
            return;
        };

        match key.code {
            KeyCode::Char('q') => self.should_quit = true,
            KeyCode::Char('j') | KeyCode::Down => self.home_move_cursor(1),
            KeyCode::Char('k') | KeyCode::Up => self.home_move_cursor(-1),
            KeyCode::Tab => {
                let Screen::Home(state) = self.router.current_mut() else {
                    return;
                };
                state.focus = match state.focus {
                    home::HomeSection::Sessions => home::HomeSection::Servers,
                    home::HomeSection::Servers => home::HomeSection::Sessions,
                };
            }
            KeyCode::Enter => {
                let sessions = home::derive_recent_sessions(&self.snapshot);
                let Screen::Home(state) = self.router.current() else {
                    return;
                };
                match state.focus {
                    home::HomeSection::Sessions => {
                        if let Some(idx) = state.sessions_state.selected() {
                            if let Some(session) = sessions.get(idx) {
                                let key = session.key.clone();
                                self.open_conversation(key);
                            }
                        }
                    }
                    home::HomeSection::Servers => {
                        // Enter on server → open sessions screen
                        self.router
                            .push(Screen::Sessions(sessions::SessionsState::default()));
                        // Load threads for all connected servers
                        self.load_thread_lists();
                    }
                }
            }
            KeyCode::Char('c') => {
                let mut disc_state = discovery::DiscoveryState::default();
                disc_state.focus = discovery::DiscoveryFocus::ManualHost;
                self.router.open_overlay(Overlay::Discovery(disc_state));
            }
            KeyCode::Char('s') => {
                self.router
                    .open_overlay(Overlay::Settings(settings::SettingsState::default()));
            }
            KeyCode::Char('d') => {
                // Disconnect selected server
                let servers = home::derive_servers(&self.snapshot);
                let Screen::Home(state) = self.router.current() else {
                    return;
                };
                if state.focus == home::HomeSection::Servers {
                    if let Some(idx) = state.servers_state.selected() {
                        if let Some(server) = servers.get(idx) {
                            self.router.open_overlay(Overlay::Confirm {
                                message: format!("Disconnect {}?", server.display_name),
                                action: ConfirmAction::DisconnectServer {
                                    server_id: server.server_id.clone(),
                                },
                            });
                        }
                    }
                }
            }
            KeyCode::Char('x') => {
                // Delete selected session
                let sessions = home::derive_recent_sessions(&self.snapshot);
                let Screen::Home(state) = self.router.current() else {
                    return;
                };
                if state.focus == home::HomeSection::Sessions {
                    if let Some(idx) = state.sessions_state.selected() {
                        if let Some(session) = sessions.get(idx) {
                            self.router.open_overlay(Overlay::Confirm {
                                message: format!("Delete \"{}\"?", session.title),
                                action: ConfirmAction::DeleteSession {
                                    server_id: session.key.server_id.clone(),
                                    thread_id: session.key.thread_id.clone(),
                                },
                            });
                        }
                    }
                }
            }
            _ => {}
        }
    }

    fn home_move_cursor(&mut self, delta: i32) {
        let Screen::Home(state) = self.router.current_mut() else {
            return;
        };
        match state.focus {
            home::HomeSection::Sessions => {
                let len = home::derive_recent_sessions(&self.snapshot).len();
                move_list_cursor(&mut state.sessions_state, len, delta);
            }
            home::HomeSection::Servers => {
                let len = home::derive_servers(&self.snapshot).len();
                move_list_cursor(&mut state.servers_state, len, delta);
            }
        }
    }

    async fn handle_sessions_key(&mut self, key: KeyEvent) {
        let Screen::Sessions(state) = self.router.current_mut() else {
            return;
        };
        match key.code {
            KeyCode::Esc => {
                self.router.pop();
            }
            KeyCode::Char('j') | KeyCode::Down => {
                let len = state.visible_keys.len();
                move_list_cursor(&mut state.list_state, len, 1);
            }
            KeyCode::Char('k') | KeyCode::Up => {
                let len = state.visible_keys.len();
                move_list_cursor(&mut state.list_state, len, -1);
            }
            KeyCode::Enter => {
                let Screen::Sessions(state) = self.router.current() else {
                    return;
                };
                if let Some(idx) = state.list_state.selected() {
                    if let Some(key) = state.visible_keys.get(idx).cloned() {
                        if !key.thread_id.is_empty() {
                            self.open_conversation(key);
                        }
                    }
                }
            }
            KeyCode::Char('/') => {
                let Screen::Sessions(state) = self.router.current_mut() else {
                    return;
                };
                state.search_active = true;
                self.mode = InputMode::Search;
            }
            KeyCode::Char('n') => {
                // New session — start a thread on the first connected server
                if let Some(server_id) = self.snapshot.servers.keys().next().cloned() {
                    let client = Arc::clone(&self.client);
                    let sid = server_id.clone();
                    self.set_status("Starting new session...".into());
                    let tx = self.bg_tx.clone();
                    tokio::spawn(async move {
                        let params = upstream::ThreadStartParams {
                            model: None,
                            model_provider: None,
                            service_tier: None,
                            cwd: None,
                            approval_policy: None,
                            approvals_reviewer: None,
                            sandbox: None,
                            config: None,
                            service_name: None,
                            base_instructions: None,
                            developer_instructions: None,
                            personality: None,
                            ephemeral: None,
                            dynamic_tools: None,
                            mock_experimental_field: None,
                            experimental_raw_events: false,
                            persist_extended_history: true,
                        };
                        if let Ok(response) = client.server_thread_start(&sid, params.clone()).await
                        {
                            let _ = client
                                .reconcile_public_rpc(
                                    "thread/start",
                                    &sid,
                                    Some(&params),
                                    &response,
                                )
                                .await;
                            let key = ThreadKey {
                                server_id: sid,
                                thread_id: response.thread.id.clone(),
                            };
                            let _ = tx.send(BgMessage::ThreadStarted(key));
                        }
                    });
                } else {
                    self.set_status("No server connected".into());
                }
            }
            KeyCode::Char('d') => {
                // Delete selected session
                let Screen::Sessions(state) = self.router.current() else {
                    return;
                };
                if let Some(idx) = state.list_state.selected() {
                    if let Some(key) = state.visible_keys.get(idx).cloned() {
                        if !key.thread_id.is_empty() {
                            self.router.open_overlay(Overlay::Confirm {
                                message: "Delete this session?".into(),
                                action: ConfirmAction::DeleteSession {
                                    server_id: key.server_id,
                                    thread_id: key.thread_id,
                                },
                            });
                        }
                    }
                }
            }
            KeyCode::Char('r') => {
                // Rename selected session
                let Screen::Sessions(state) = self.router.current() else {
                    return;
                };
                if let Some(idx) = state.list_state.selected() {
                    if let Some(key) = state.visible_keys.get(idx).cloned() {
                        if !key.thread_id.is_empty() {
                            // For now, set a placeholder name; a proper rename would need a text input popup
                            let client = Arc::clone(&self.client);
                            tokio::spawn(async move {
                                let params = upstream::ThreadSetNameParams {
                                    thread_id: key.thread_id.clone(),
                                    name: "Renamed Session".into(),
                                };
                                if let Ok(response) = client
                                    .server_thread_set_name(&key.server_id, params.clone())
                                    .await
                                {
                                    let _ = client
                                        .reconcile_public_rpc(
                                            "thread/setName",
                                            &key.server_id,
                                            Some(&params),
                                            &response,
                                        )
                                        .await;
                                }
                            });
                            self.set_status("Session renamed".into());
                        }
                    }
                }
            }
            _ => {}
        }
    }

    async fn handle_conversation_key(&mut self, key: KeyEvent) {
        // Approval keys
        if let Some(approval) = self.active_thread_approval() {
            match key.code {
                KeyCode::Char('y') => {
                    let id = approval.id.clone();
                    let client = Arc::clone(&self.client);
                    tokio::spawn(async move {
                        let _ = client
                            .respond_to_approval(&id, ApprovalDecisionValue::Accept)
                            .await;
                    });
                    return;
                }
                KeyCode::Char('n') => {
                    let id = approval.id.clone();
                    let client = Arc::clone(&self.client);
                    tokio::spawn(async move {
                        let _ = client
                            .respond_to_approval(&id, ApprovalDecisionValue::Decline)
                            .await;
                    });
                    return;
                }
                KeyCode::Char('a') => {
                    let id = approval.id.clone();
                    let client = Arc::clone(&self.client);
                    tokio::spawn(async move {
                        let _ = client
                            .respond_to_approval(&id, ApprovalDecisionValue::AcceptForSession)
                            .await;
                    });
                    return;
                }
                KeyCode::Char('x') => {
                    let id = approval.id.clone();
                    let client = Arc::clone(&self.client);
                    tokio::spawn(async move {
                        let _ = client
                            .respond_to_approval(&id, ApprovalDecisionValue::Cancel)
                            .await;
                    });
                    return;
                }
                _ => {}
            }
        }

        let Screen::Conversation(state) = self.router.current_mut() else {
            return;
        };
        match key.code {
            KeyCode::Esc => {
                self.router.pop();
            }
            KeyCode::Char('i') | KeyCode::Enter => {
                self.mode = InputMode::Insert;
            }
            KeyCode::Char('j') | KeyCode::Down => {
                state.auto_scroll = false;
                state.scroll_offset = state.scroll_offset.saturating_add(1);
            }
            KeyCode::Char('k') | KeyCode::Up => {
                state.auto_scroll = false;
                state.scroll_offset = state.scroll_offset.saturating_sub(1);
            }
            KeyCode::Char('g') => {
                state.auto_scroll = false;
                state.scroll_offset = 0;
            }
            KeyCode::Char('G') => {
                state.auto_scroll = true;
            }
            KeyCode::PageDown => {
                state.auto_scroll = false;
                state.scroll_offset = state.scroll_offset.saturating_add(20);
            }
            KeyCode::PageUp => {
                state.auto_scroll = false;
                state.scroll_offset = state.scroll_offset.saturating_sub(20);
            }
            _ => {
                if key.modifiers.contains(KeyModifiers::CONTROL) {
                    match key.code {
                        KeyCode::Char('d') => {
                            state.auto_scroll = false;
                            state.scroll_offset = state.scroll_offset.saturating_add(10);
                        }
                        KeyCode::Char('u') => {
                            state.auto_scroll = false;
                            state.scroll_offset = state.scroll_offset.saturating_sub(10);
                        }
                        KeyCode::Char('c') => self.interrupt_active_turn(),
                        _ => {}
                    }
                }
            }
        }
    }

    // ── Insert mode ──────────────────────────────────────────────────

    async fn handle_insert_key(&mut self, key: KeyEvent) {
        if key.modifiers.contains(KeyModifiers::CONTROL) {
            match key.code {
                KeyCode::Char('s') => {
                    self.send_message().await;
                    return;
                }
                KeyCode::Char('c') => {
                    self.interrupt_active_turn();
                    self.mode = InputMode::Normal;
                    return;
                }
                _ => {}
            }
        }

        match key.code {
            KeyCode::Esc => self.mode = InputMode::Normal,
            KeyCode::Char(c) => {
                if let Screen::Conversation(state) = self.router.current_mut() {
                    state.composer_text.push(c);
                }
            }
            KeyCode::Backspace => {
                if let Screen::Conversation(state) = self.router.current_mut() {
                    state.composer_text.pop();
                }
            }
            KeyCode::Enter => {
                if key.modifiers.contains(KeyModifiers::SHIFT)
                    || key.modifiers.contains(KeyModifiers::ALT)
                {
                    // Shift+Enter or Alt+Enter → newline
                    if let Screen::Conversation(state) = self.router.current_mut() {
                        state.composer_text.push('\n');
                    }
                } else {
                    // Enter → send
                    self.send_message().await;
                }
            }
            _ => {}
        }
    }

    // ── Search mode ──────────────────────────────────────────────────

    async fn handle_search_key(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::Esc | KeyCode::Enter => {
                if let Screen::Sessions(state) = self.router.current_mut() {
                    state.search_active = false;
                }
                self.mode = InputMode::Normal;
            }
            KeyCode::Char(c) => {
                if let Screen::Sessions(state) = self.router.current_mut() {
                    state.search_query.push(c);
                }
            }
            KeyCode::Backspace => {
                if let Screen::Sessions(state) = self.router.current_mut() {
                    state.search_query.pop();
                }
            }
            _ => {}
        }
    }

    // ── User input prompt ────────────────────────────────────────────

    async fn handle_user_input_key(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::Esc => {
                self.user_input_text.clear();
            }
            KeyCode::Char(c) => {
                self.user_input_text.push(c);
            }
            KeyCode::Backspace => {
                self.user_input_text.pop();
            }
            KeyCode::Enter => {
                if let Some(request) = self.active_thread_user_input() {
                    let request_id = request.id.clone();
                    let answers = request
                        .questions
                        .iter()
                        .map(|q| codex_mobile_client::types::PendingUserInputAnswer {
                            question_id: q.id.clone(),
                            answers: vec![self.user_input_text.clone()],
                        })
                        .collect();
                    let client = Arc::clone(&self.client);
                    tokio::spawn(async move {
                        let _ = client.respond_to_user_input(&request_id, answers).await;
                    });
                    self.user_input_text.clear();
                }
            }
            _ => {}
        }
    }

    // ── Actions ──────────────────────────────────────────────────────

    async fn send_message(&mut self) {
        let Screen::Conversation(state) = self.router.current_mut() else {
            return;
        };
        let text = state.composer_text.trim().to_string();
        if text.is_empty() {
            return;
        }

        let thread_key = state.thread_key.clone();
        state.composer_text.clear();
        state.auto_scroll = true;
        self.mode = InputMode::Normal;

        let client = Arc::clone(&self.client);
        tokio::spawn(async move {
            let params = upstream::TurnStartParams {
                thread_id: thread_key.thread_id.clone(),
                input: vec![upstream::UserInput::Text {
                    text,
                    text_elements: vec![],
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
            };
            if let Ok(response) = client
                .server_turn_start(&thread_key.server_id, params.clone())
                .await
            {
                let _ = client
                    .reconcile_public_rpc(
                        "turn/start",
                        &thread_key.server_id,
                        Some(&params),
                        &response,
                    )
                    .await;
            }
        });
    }

    fn connect_from_discovery(&mut self) {
        let Some(Overlay::Discovery(state)) = &self.router.overlay else {
            return;
        };

        let config = if !state.manual_host.is_empty() {
            let host = state.manual_host.clone();
            let port: u16 = state.manual_port.parse().unwrap_or(8390);
            Some(codex_mobile_client::session::connection::ServerConfig {
                server_id: format!("{host}:{port}"),
                display_name: host.clone(),
                host,
                port,
                websocket_url: None,
                is_local: false,
                tls: false,
            })
        } else if let Some(idx) = state.list_state.selected() {
            state.servers.get(idx).map(|server| {
                codex_mobile_client::session::connection::ServerConfig {
                    server_id: server.id.clone(),
                    display_name: server.name.clone(),
                    host: server.host.clone(),
                    port: server.port,
                    websocket_url: None,
                    is_local: false,
                    tls: false,
                }
            })
        } else {
            None
        };

        if let Some(config) = config {
            self.set_status("Connecting...".into());
            let client = Arc::clone(&self.client);
            let tx = self.bg_tx.clone();
            tokio::spawn(async move {
                match client.connect_remote(config).await {
                    Ok(_) => {
                        let _ = tx.send(BgMessage::ServerConnected);
                    }
                    Err(e) => {
                        let _ =
                            tx.send(BgMessage::StatusMessage(format!("Connection failed: {e}")));
                    }
                }
            });
        }
    }

    fn run_discovery_scan(&mut self) {
        // Network discovery (mDNS, LAN probe, ARP scan) is slow (5-10s).
        // Run on a dedicated thread so the UI stays responsive.
        if let Some(Overlay::Discovery(state)) = &mut self.router.overlay {
            state.is_scanning = true;
            state.status_message = Some("Scanning network (may take a few seconds)...".into());
        }
        let client = Arc::clone(&self.client);
        let tx = self.bg_tx.clone();
        std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("discovery runtime");
            rt.block_on(async move {
                let discovered = client.scan_servers_with_mdns_context(vec![], None).await;
                let entries = discovered
                    .into_iter()
                    .map(|s| discovery::DiscoveredServerEntry {
                        id: s.id.clone(),
                        name: s.display_name.clone(),
                        host: s.host.clone(),
                        port: s.codex_port.unwrap_or(s.port),
                        source: format!("{:?}", s.source),
                        reachable: s.reachable,
                    })
                    .collect();
                let _ = tx.send(BgMessage::DiscoveryScanDone(entries));
            });
        });
    }

    fn handle_bg_message(&mut self, msg: BgMessage) {
        match msg {
            BgMessage::DiscoveryScanDone(entries) => {
                if let Some(Overlay::Discovery(state)) = &mut self.router.overlay {
                    state.is_scanning = false;
                    state.servers = entries;
                    if !state.servers.is_empty() && state.list_state.selected().is_none() {
                        state.list_state.select(Some(0));
                    }
                }
            }
            BgMessage::ThreadStarted(key) => {
                self.snapshot = self.client.app_snapshot();
                self.client.set_active_thread(Some(key.clone()));
                self.router
                    .push(Screen::Conversation(conversation::ConversationState::new(
                        key,
                    )));
            }
            BgMessage::ServerConnected => {
                self.router.close_overlay();
                self.snapshot = self.client.app_snapshot();
                self.set_status("Connected!".into());
                self.load_thread_lists();
            }
            BgMessage::StatusMessage(msg) => {
                self.set_status(msg);
            }
        }
    }

    fn load_thread_lists(&self) {
        for server_id in self.snapshot.servers.keys() {
            let client = Arc::clone(&self.client);
            let sid = server_id.clone();
            tokio::spawn(async move {
                let params = upstream::ThreadListParams {
                    limit: None,
                    cursor: None,
                    sort_key: None,
                    model_providers: None,
                    source_kinds: None,
                    archived: None,
                    cwd: None,
                    search_term: None,
                };
                if let Ok(response) = client.server_thread_list(&sid, params.clone()).await {
                    // Reconcile into the store so snapshot picks up the threads
                    let _ = client
                        .reconcile_public_rpc("thread/list", &sid, Some(&params), &response)
                        .await;
                }
            });
        }
    }

    async fn execute_confirm_action(&mut self, action: ConfirmAction) {
        match action {
            ConfirmAction::DisconnectServer { server_id } => {
                self.client.disconnect_server(&server_id);
                self.snapshot = self.client.app_snapshot();
            }
            ConfirmAction::DeleteSession {
                server_id,
                thread_id,
            } => {
                let client = Arc::clone(&self.client);
                tokio::spawn(async move {
                    let params = upstream::ThreadArchiveParams {
                        thread_id: thread_id.clone(),
                    };
                    if let Ok(response) = client
                        .server_thread_archive(&server_id, params.clone())
                        .await
                    {
                        let _ = client
                            .reconcile_public_rpc(
                                "thread/archive",
                                &server_id,
                                Some(&params),
                                &response,
                            )
                            .await;
                    }
                });
            }
        }
    }

    fn interrupt_active_turn(&self) {
        if let Screen::Conversation(state) = self.router.current() {
            let thread_key = state.thread_key.clone();
            if let Some(thread) = self.snapshot.threads.get(&thread_key) {
                if let Some(turn_id) = thread.active_turn_id.clone() {
                    let client = Arc::clone(&self.client);
                    tokio::spawn(async move {
                        let params = upstream::TurnInterruptParams {
                            thread_id: thread_key.thread_id.clone(),
                            turn_id,
                        };
                        if let Ok(response) = client
                            .server_turn_interrupt(&thread_key.server_id, params.clone())
                            .await
                        {
                            let _ = client
                                .reconcile_public_rpc(
                                    "turn/interrupt",
                                    &thread_key.server_id,
                                    Some(&params),
                                    &response,
                                )
                                .await;
                        }
                    });
                }
            }
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────

    fn active_thread_approval(&self) -> Option<codex_mobile_client::types::PendingApproval> {
        if let Screen::Conversation(state) = self.router.current() {
            self.snapshot
                .pending_approvals
                .iter()
                .find(|a| {
                    a.thread_id
                        .as_ref()
                        .map(|tid| tid == &state.thread_key.thread_id)
                        .unwrap_or(false)
                })
                .cloned()
        } else {
            None
        }
    }

    fn active_thread_user_input(
        &self,
    ) -> Option<codex_mobile_client::types::PendingUserInputRequest> {
        if let Screen::Conversation(state) = self.router.current() {
            self.snapshot
                .pending_user_inputs
                .iter()
                .find(|r| r.thread_id == state.thread_key.thread_id)
                .cloned()
        } else {
            None
        }
    }

    fn open_conversation(&mut self, key: ThreadKey) {
        self.client.set_active_thread(Some(key.clone()));

        // Navigate immediately — the conversation view will show whatever
        // items are already in the snapshot (may be empty until resume completes).
        self.router
            .push(Screen::Conversation(conversation::ConversationState::new(
                key.clone(),
            )));

        // Resume the thread in the background to load full conversation history.
        let client = Arc::clone(&self.client);
        tokio::spawn(async move {
            let params = upstream::ThreadResumeParams {
                thread_id: key.thread_id.clone(),
                history: None,
                path: None,
                model: None,
                model_provider: None,
                service_tier: None,
                cwd: None,
                approval_policy: None,
                approvals_reviewer: None,
                sandbox: None,
                config: None,
                base_instructions: None,
                developer_instructions: None,
                personality: None,
                persist_extended_history: true,
            };
            if let Ok(response) = client
                .server_thread_resume(&key.server_id, params.clone())
                .await
            {
                let _ = client
                    .reconcile_public_rpc("thread/resume", &key.server_id, Some(&params), &response)
                    .await;
            }
        });
    }

    fn set_status(&mut self, msg: String) {
        self.status_message = Some((msg, Instant::now()));
    }
}

fn move_list_cursor(list_state: &mut ratatui::widgets::ListState, len: usize, delta: i32) {
    if len == 0 {
        return;
    }
    let current = list_state.selected().unwrap_or(0) as i32;
    let next = (current + delta).rem_euclid(len as i32) as usize;
    list_state.select(Some(next));
}
