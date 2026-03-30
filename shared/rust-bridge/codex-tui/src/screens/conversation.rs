use codex_mobile_client::store::{AppSnapshot, ThreadSnapshot};
use codex_mobile_client::types::ThreadKey;
use ratatui::{
    Frame,
    layout::{Alignment, Constraint, Layout, Rect},
    style::Style,
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph, Scrollbar, ScrollbarOrientation, ScrollbarState},
};

use crate::theme;
use crate::widgets::message_list;

#[derive(Debug)]
pub struct ConversationState {
    pub thread_key: ThreadKey,
    pub scroll_offset: u16,
    pub total_lines: u16,
    pub composer_text: String,
    pub auto_scroll: bool,
    pub last_item_count: usize,
}

impl ConversationState {
    pub fn new(key: ThreadKey) -> Self {
        Self {
            thread_key: key,
            scroll_offset: 0,
            total_lines: 0,
            composer_text: String::new(),
            auto_scroll: true,
            last_item_count: 0,
        }
    }
}

pub fn render(
    frame: &mut Frame,
    area: Rect,
    state: &mut ConversationState,
    snapshot: &AppSnapshot,
    insert_mode: bool,
) {
    let thread = snapshot.threads.get(&state.thread_key);

    // Layout: header(1) | messages(flex) | indicators(1) | composer(3)
    let chunks = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(1),
        Constraint::Length(1),
        Constraint::Length(3),
    ])
    .split(area);

    render_header(frame, chunks[0], thread);

    if let Some(thread) = thread {
        // Messages
        let msg_area = chunks[1];
        let rendered = message_list::render_items(&thread.items, msg_area.width.saturating_sub(2));
        let new_total = rendered.len() as u16;

        // Auto-scroll when new content arrives during active turn
        if thread.items.len() != state.last_item_count || new_total > state.total_lines {
            if thread.active_turn_id.is_some() {
                state.auto_scroll = true;
            }
            state.last_item_count = thread.items.len();
        }

        state.total_lines = new_total;
        let visible_height = msg_area.height.saturating_sub(2);
        let max_scroll = state.total_lines.saturating_sub(visible_height);

        if state.auto_scroll {
            state.scroll_offset = max_scroll;
        }
        state.scroll_offset = state.scroll_offset.min(max_scroll);

        let visible_lines: Vec<Line> = rendered
            .into_iter()
            .skip(state.scroll_offset as usize)
            .take(visible_height as usize)
            .collect();

        let block = Block::default()
            .borders(Borders::LEFT | Borders::RIGHT)
            .border_style(theme::border());
        frame.render_widget(Paragraph::new(visible_lines).block(block), msg_area);

        if state.total_lines > visible_height {
            let mut sb = ScrollbarState::new(state.total_lines as usize)
                .position(state.scroll_offset as usize);
            frame.render_stateful_widget(
                Scrollbar::new(ScrollbarOrientation::VerticalRight),
                msg_area,
                &mut sb,
            );
        }

        // Indicators bar (context + rate limits)
        let server = snapshot.servers.get(&state.thread_key.server_id);
        render_indicators(frame, chunks[2], thread, server);

        // Composer
        render_composer(frame, chunks[3], state, insert_mode);
    } else {
        frame.render_widget(
            Paragraph::new(" No thread loaded").style(theme::dim()),
            chunks[1],
        );
        render_composer(frame, chunks[3], state, insert_mode);
    }
}

fn render_header(frame: &mut Frame, area: Rect, thread: Option<&ThreadSnapshot>) {
    let spans = if let Some(t) = thread {
        let title = t.info.title.as_deref().unwrap_or("Untitled");
        let model = t.model.as_deref().unwrap_or("—");
        let effort = t.reasoning_effort.as_deref().unwrap_or("");
        let active = if t.active_turn_id.is_some() {
            " ⟳"
        } else {
            ""
        };
        let effort_str = if effort.is_empty() {
            String::new()
        } else {
            format!("  RE:{effort}")
        };
        vec![
            Span::styled(format!(" {title}"), theme::bold()),
            Span::raw(" ── "),
            Span::styled(model, theme::accent()),
            Span::styled(effort_str, theme::secondary()),
            Span::styled(active, theme::accent()),
        ]
    } else {
        vec![Span::styled(" (no thread)", theme::dim())]
    };
    frame.render_widget(
        Paragraph::new(Line::from(spans)).style(Style::default().bg(theme::CODE_BG)),
        area,
    );
}

fn render_indicators(
    frame: &mut Frame,
    area: Rect,
    thread: &ThreadSnapshot,
    server: Option<&codex_mobile_client::store::ServerSnapshot>,
) {
    let mut badges: Vec<Span> = Vec::new();

    // Rate limit badges from server (primary + secondary windows)
    // iOS shows these as "[duration ██░░ XX%]" badges
    if let Some(srv) = server {
        if let Some(rl_snap) = &srv.rate_limits {
            for window in [&rl_snap.primary, &rl_snap.secondary].into_iter().flatten() {
                let used = (window.used_percent as u16).min(100);
                let remaining = 100u16.saturating_sub(used);
                let label = format_window_duration(window.window_duration_mins);
                let color = badge_color_for_remaining(remaining);
                badges.push(render_badge(&label, remaining, color));
                badges.push(Span::raw(" "));
            }
        }
    }

    // Context window badge — iOS reserves 12k baseline
    match (thread.context_tokens_used, thread.model_context_window) {
        (Some(used), Some(window)) if window > 0 => {
            let baseline: u64 = 12_000;
            let effective_window = window.saturating_sub(baseline);
            if effective_window > 0 {
                let used_above = used.saturating_sub(baseline);
                let remaining_tokens = effective_window.saturating_sub(used_above);
                let remaining_pct =
                    ((remaining_tokens as f64 / effective_window as f64) * 100.0).round() as u16;
                let remaining_pct = remaining_pct.min(100);
                let color = context_color_for_remaining(remaining_pct);
                badges.push(render_badge("ctx", remaining_pct, color));
            }
        }
        _ => {}
    }

    if badges.is_empty() {
        return;
    }

    frame.render_widget(
        Paragraph::new(Line::from(badges)).alignment(Alignment::Right),
        area,
    );
}

/// Render a single badge: `label ████░░ XX%`
fn render_badge(label: &str, remaining_pct: u16, color: ratatui::style::Color) -> Span<'static> {
    let bar_w = 6u16;
    let filled = ((remaining_pct as u32 * bar_w as u32) / 100) as u16;
    let empty = bar_w.saturating_sub(filled);
    let fill_str = "█".repeat(filled as usize);
    let empty_str = "░".repeat(empty as usize);
    Span::styled(
        format!("{label} {fill_str}{empty_str} {remaining_pct}%"),
        Style::default().fg(color),
    )
}

/// Rate limit color: based on remaining %
fn badge_color_for_remaining(remaining: u16) -> ratatui::style::Color {
    if remaining <= 10 {
        theme::ERROR
    } else if remaining <= 30 {
        theme::WARNING
    } else {
        theme::FG_DIM
    }
}

/// Context color: based on remaining %
fn context_color_for_remaining(remaining: u16) -> ratatui::style::Color {
    if remaining <= 15 {
        theme::ERROR
    } else if remaining <= 35 {
        theme::WARNING
    } else {
        theme::SUCCESS
    }
}

/// Format window duration: 1440 → "1d", 60 → "1h", 30 → "30m"
fn format_window_duration(mins: Option<i64>) -> String {
    match mins {
        Some(m) if m >= 1440 => format!("{}d", m / 1440),
        Some(m) if m >= 60 => format!("{}h", m / 60),
        Some(m) => format!("{m}m"),
        None => "—".into(),
    }
}

fn render_composer(frame: &mut Frame, area: Rect, state: &ConversationState, insert_mode: bool) {
    let border_style = if insert_mode {
        theme::border_focused()
    } else {
        theme::border()
    };

    let title = if insert_mode {
        " INSERT  Enter:send  Esc:cancel "
    } else {
        " i:type  Enter:send "
    };

    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(border_style)
        .title(title);

    let text = if state.composer_text.is_empty() && !insert_mode {
        Span::styled("Type a message...", theme::dim())
    } else {
        Span::raw(&state.composer_text)
    };

    frame.render_widget(Paragraph::new(Line::from(text)).block(block), area);
}
