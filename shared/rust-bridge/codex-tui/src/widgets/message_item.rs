use codex_mobile_client::conversation::*;
use ratatui::{
    style::{Color, Modifier, Style},
    text::{Line, Span},
};

use crate::markdown;
use crate::theme;

pub fn render(item: &ConversationItem, width: u16) -> Vec<Line<'static>> {
    match &item.content {
        ConversationItemContent::User(data) => render_user(data),
        ConversationItemContent::Assistant(data) => render_assistant(data, width),
        ConversationItemContent::Reasoning(data) => render_reasoning(data),
        ConversationItemContent::CommandExecution(data) => render_command(data),
        ConversationItemContent::FileChange(data) => render_file_change(data),
        ConversationItemContent::TurnDiff(data) => render_turn_diff(data),
        ConversationItemContent::McpToolCall(data) => render_mcp_tool_call(data),
        ConversationItemContent::DynamicToolCall(data) => render_dynamic_tool_call(data),
        ConversationItemContent::MultiAgentAction(data) => render_multi_agent(data),
        ConversationItemContent::WebSearch(data) => render_web_search(data),
        ConversationItemContent::TodoList(data) => render_todo_list(data),
        ConversationItemContent::ProposedPlan(data) => render_proposed_plan(data),
        ConversationItemContent::Widget(data) => render_widget(data),
        ConversationItemContent::UserInputResponse(data) => render_user_input_response(data),
        ConversationItemContent::Divider(data) => render_divider(data),
        ConversationItemContent::Error(data) => render_error(data),
        ConversationItemContent::Note(data) => render_note(data),
    }
}

fn render_user(data: &UserMessageData) -> Vec<Line<'static>> {
    let mut lines = vec![Line::from(Span::styled(
        " ▌You",
        Style::default()
            .fg(theme::ACCENT)
            .add_modifier(Modifier::BOLD),
    ))];
    for text_line in data.text.lines() {
        lines.push(Line::from(Span::styled(
            format!(" > {text_line}"),
            theme::user_msg(),
        )));
    }
    lines
}

fn render_assistant(data: &AssistantMessageData, width: u16) -> Vec<Line<'static>> {
    let label = if let Some(nick) = &data.agent_nickname {
        format!(" ▌{nick}")
    } else {
        " ▌Assistant".to_string()
    };

    let mut lines = vec![Line::from(Span::styled(
        label,
        Style::default().fg(theme::FG).add_modifier(Modifier::BOLD),
    ))];

    let md_lines = markdown::render(&data.text, width.saturating_sub(2));
    lines.extend(md_lines);
    lines
}

fn render_reasoning(data: &ReasoningData) -> Vec<Line<'static>> {
    let summary_text = if data.summary.is_empty() {
        "Thinking...".to_string()
    } else {
        data.summary.join("; ")
    };
    vec![Line::from(Span::styled(
        format!(" ◆ {summary_text}"),
        theme::reasoning(),
    ))]
}

fn render_command(data: &CommandExecutionData) -> Vec<Line<'static>> {
    let mut lines = Vec::new();
    let status_style = match data.exit_code {
        Some(0) => Style::default().fg(theme::SUCCESS),
        Some(_) => Style::default().fg(theme::ERROR),
        None => theme::dim(),
    };

    lines.push(Line::from(vec![
        Span::styled(" ┌─ bash ", Style::default().fg(theme::BORDER)),
        Span::styled("─".repeat(30), Style::default().fg(theme::BORDER)),
    ]));
    lines.push(Line::from(vec![
        Span::styled(" │ $ ", theme::dim()),
        Span::styled(data.command.clone(), theme::bold()),
    ]));

    if let Some(ref output) = data.output {
        let output_lines: Vec<&str> = output.lines().take(10).collect();
        for ol in &output_lines {
            lines.push(Line::from(Span::styled(format!(" │ {ol}"), theme::dim())));
        }
        let total_lines = output.lines().count();
        if total_lines > 10 {
            lines.push(Line::from(Span::styled(
                format!(" │ ... ({} more lines)", total_lines - 10),
                theme::dim(),
            )));
        }
    }

    let exit_text = match data.exit_code {
        Some(code) => format!("exit: {code}"),
        None => "running...".into(),
    };
    lines.push(Line::from(vec![
        Span::styled(" │ ", theme::dim()),
        Span::styled(exit_text, status_style),
    ]));
    lines.push(Line::from(Span::styled(
        format!(" └{}", "─".repeat(40)),
        Style::default().fg(theme::BORDER),
    )));
    lines
}

fn render_file_change(data: &FileChangeData) -> Vec<Line<'static>> {
    let mut lines = Vec::new();

    lines.push(Line::from(vec![
        Span::styled(" ┌─ files ", Style::default().fg(theme::BORDER)),
        Span::styled(format!("({}) ", data.status), theme::secondary()),
        Span::styled("─".repeat(25), Style::default().fg(theme::BORDER)),
    ]));

    for change in &data.changes {
        let kind_indicator = match change.kind.as_str() {
            "create" | "add" => ("+", theme::SUCCESS),
            "delete" | "remove" => ("-", theme::ERROR),
            _ => ("M", theme::WARNING),
        };
        lines.push(Line::from(vec![
            Span::styled(" │ ", theme::dim()),
            Span::styled(
                format!("{} ", kind_indicator.0),
                Style::default().fg(kind_indicator.1),
            ),
            Span::styled(change.path.clone(), theme::accent()),
        ]));

        // Show diff lines (truncated)
        for diff_line in change.diff.lines().take(10) {
            let style = if diff_line.starts_with('+') {
                theme::diff_add()
            } else if diff_line.starts_with('-') {
                theme::diff_remove()
            } else {
                theme::dim()
            };
            lines.push(Line::from(Span::styled(format!(" │   {diff_line}"), style)));
        }
    }

    lines.push(Line::from(Span::styled(
        format!(" └{}", "─".repeat(40)),
        Style::default().fg(theme::BORDER),
    )));
    lines
}

fn render_mcp_tool_call(data: &McpToolCallData) -> Vec<Line<'static>> {
    let status_style = match data.status.as_str() {
        "completed" => Style::default().fg(theme::SUCCESS),
        "failed" | "error" => Style::default().fg(theme::ERROR),
        _ => theme::secondary(),
    };

    vec![
        Line::from(vec![
            Span::styled(" ┌─ mcp: ", Style::default().fg(theme::BORDER)),
            Span::styled(format!("{}:{}", data.server, data.tool), theme::accent()),
        ]),
        Line::from(vec![
            Span::styled(" │ status: ", theme::dim()),
            Span::styled(data.status.clone(), status_style),
        ]),
        Line::from(Span::styled(
            format!(" └{}", "─".repeat(40)),
            Style::default().fg(theme::BORDER),
        )),
    ]
}

fn render_turn_diff(data: &TurnDiffData) -> Vec<Line<'static>> {
    let mut lines = vec![Line::from(Span::styled(" Diff:", theme::bold()))];
    for diff_line in data.diff.lines().take(12) {
        let style = if diff_line.starts_with('+') {
            theme::diff_add()
        } else if diff_line.starts_with('-') {
            theme::diff_remove()
        } else {
            theme::dim()
        };
        lines.push(Line::from(Span::styled(format!("   {diff_line}"), style)));
    }
    lines
}

fn render_dynamic_tool_call(data: &DynamicToolCallData) -> Vec<Line<'static>> {
    vec![Line::from(vec![
        Span::styled(" ⚙ ", theme::dim()),
        Span::styled(data.tool.clone(), theme::accent()),
        Span::raw(format!(" [{}]", data.status)),
    ])]
}

fn render_multi_agent(data: &MultiAgentActionData) -> Vec<Line<'static>> {
    let mut lines = vec![Line::from(vec![
        Span::styled(" ┌─ agent: ", Style::default().fg(theme::BORDER)),
        Span::styled(data.tool.clone(), theme::accent()),
    ])];

    for state in &data.agent_states {
        lines.push(Line::from(vec![
            Span::styled(" │ ", theme::dim()),
            Span::styled(state.target_id.clone(), Style::default().fg(Color::Magenta)),
            Span::raw(format!(" [{}]", state.status)),
        ]));
    }

    lines.push(Line::from(Span::styled(
        format!(" └{}", "─".repeat(40)),
        Style::default().fg(theme::BORDER),
    )));
    lines
}

fn render_web_search(data: &WebSearchData) -> Vec<Line<'static>> {
    let indicator = if data.is_in_progress { "..." } else { "" };
    vec![Line::from(vec![
        Span::styled(" 🔍 ", theme::dim()),
        Span::styled(data.query.clone(), theme::accent()),
        Span::raw(indicator),
    ])]
}

fn render_widget(data: &WidgetData) -> Vec<Line<'static>> {
    vec![
        Line::from(vec![
            Span::styled(" Widget: ", theme::bold()),
            Span::styled(data.title.clone(), theme::accent()),
        ]),
        Line::from(Span::styled(
            format!(
                "   status={} size={}x{}{}",
                data.status,
                data.width,
                data.height,
                if data.is_finalized { " finalized" } else { "" }
            ),
            theme::secondary(),
        )),
    ]
}

fn render_user_input_response(data: &UserInputResponseData) -> Vec<Line<'static>> {
    let mut lines = vec![Line::from(Span::styled(" User Input:", theme::bold()))];
    for question in &data.questions {
        lines.push(Line::from(Span::styled(
            format!("   {}: {}", question.question, question.answer),
            theme::secondary(),
        )));
    }
    lines
}

fn render_todo_list(data: &TodoListData) -> Vec<Line<'static>> {
    let mut lines = vec![Line::from(Span::styled(" Plan:", theme::bold()))];
    for step in &data.steps {
        let check = match step.status.as_str() {
            "completed" => "✓",
            "in_progress" => "⟳",
            _ => "○",
        };
        let style = match step.status.as_str() {
            "completed" => theme::dim(),
            _ => theme::accent(),
        };
        lines.push(Line::from(vec![
            Span::raw("   "),
            Span::styled(format!("[{check}] "), style),
            Span::raw(step.step.clone()),
        ]));
    }
    lines
}

fn render_proposed_plan(data: &ProposedPlanData) -> Vec<Line<'static>> {
    let mut lines = vec![Line::from(vec![
        Span::styled(" ┌─ plan ", Style::default().fg(theme::BORDER)),
        Span::styled("─".repeat(30), Style::default().fg(theme::BORDER)),
    ])];

    for text_line in data.content.lines() {
        lines.push(Line::from(Span::styled(
            format!(" │ {text_line}"),
            theme::secondary(),
        )));
    }

    lines.push(Line::from(Span::styled(
        format!(" └{}", "─".repeat(40)),
        Style::default().fg(theme::BORDER),
    )));
    lines
}

fn render_divider(data: &DividerData) -> Vec<Line<'static>> {
    let label = match data {
        DividerData::ContextCompaction { .. } => "── context compacted ──",
        DividerData::ModelRerouted { .. } => "── model rerouted ──",
        DividerData::ReviewEntered { .. } => "── review entered ──",
        DividerData::ReviewExited { .. } => "── review exited ──",
    };
    vec![Line::from(Span::styled(format!(" {label}"), theme::dim()))]
}

fn render_error(data: &ErrorData) -> Vec<Line<'static>> {
    let mut lines = vec![Line::from(Span::styled(
        format!(" Error: {}", data.title),
        Style::default()
            .fg(theme::ERROR)
            .add_modifier(Modifier::BOLD),
    ))];
    lines.push(Line::from(Span::styled(
        format!("   {}", data.message),
        Style::default().fg(theme::ERROR),
    )));
    if let Some(details) = &data.details {
        for line in details.lines().take(8) {
            lines.push(Line::from(Span::styled(format!("   {line}"), theme::dim())));
        }
    }
    lines
}

fn render_note(data: &NoteData) -> Vec<Line<'static>> {
    let mut lines = vec![Line::from(Span::styled(
        format!(" 📝 {}", data.title),
        theme::bold(),
    ))];
    for text_line in data.body.lines() {
        lines.push(Line::from(Span::styled(
            format!("   {text_line}"),
            theme::secondary(),
        )));
    }
    lines
}
