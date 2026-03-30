use codex_mobile_client::store::AppSnapshot;
use ratatui::{
    Frame,
    layout::{Constraint, Layout, Rect},
    style::Modifier,
    text::{Line, Span},
    widgets::{Block, Borders, Clear, List, ListItem, ListState, Paragraph},
};

use crate::theme;
use crate::widgets::popup;

#[derive(Debug, Default)]
pub struct SettingsState {
    pub list_state: ListState,
}

pub fn render(frame: &mut Frame, area: Rect, state: &mut SettingsState, snapshot: &AppSnapshot) {
    let popup_area = popup::centered_rect(95, 80, area);
    frame.render_widget(Clear, popup_area);

    let block = Block::default()
        .title(" Settings ")
        .borders(Borders::ALL)
        .border_style(theme::border_focused());

    let inner = block.inner(popup_area);
    frame.render_widget(block, popup_area);

    let chunks = Layout::vertical([
        Constraint::Min(4),
        Constraint::Length(3),
        Constraint::Length(1),
    ])
    .split(inner);

    // Settings items
    let mut items = Vec::new();

    // Show connected servers
    items.push(ListItem::new(Line::from(vec![Span::styled(
        " Connected Servers:",
        theme::bold(),
    )])));

    for server in snapshot.servers.values() {
        let health_sym = theme::health_symbol(&server.health);
        let health_col = theme::health_color(&server.health);
        items.push(ListItem::new(Line::from(vec![
            Span::styled(
                format!("   {health_sym} "),
                ratatui::style::Style::default().fg(health_col),
            ),
            Span::styled(&server.display_name, theme::accent()),
            Span::raw(format!(" ({}:{})", server.host, server.port)),
        ])));
    }

    if snapshot.servers.is_empty() {
        items.push(ListItem::new(Span::styled(
            "   No servers connected",
            theme::dim(),
        )));
    }

    // Account info
    items.push(ListItem::new(Line::default()));
    items.push(ListItem::new(Line::from(vec![Span::styled(
        " Account:",
        theme::bold(),
    )])));

    for server in snapshot.servers.values() {
        if let Some(account) = &server.account {
            use codex_mobile_client::types::AppAccount;
            let label = match account {
                AppAccount::Chatgpt { email, .. } => email.clone(),
                AppAccount::ApiKey => "API Key".to_string(),
            };
            items.push(ListItem::new(Line::from(vec![
                Span::raw("   "),
                Span::styled(&server.display_name, theme::secondary()),
                Span::raw(": "),
                Span::styled(label, theme::accent()),
            ])));
        }
    }

    let list = List::new(items).highlight_style(theme::accent().add_modifier(Modifier::REVERSED));
    frame.render_stateful_widget(list, chunks[0], &mut state.list_state);

    // Hints
    let hints = Line::from(vec![
        Span::styled(" Esc", theme::accent()),
        Span::raw(":close"),
    ]);
    frame.render_widget(Paragraph::new(hints), chunks[2]);
}
