//! Generative UI dynamic tool specs and `visualize_read_me` handler.
//!
//! The tool specs are defined here so both iOS and Android can register
//! the same tools via a single UniFFI call. The `visualize_read_me`
//! response is assembled from embedded markdown guidelines.

use crate::types::models::AppDynamicToolSpec;

// ── Embedded guideline sections ─────────────────────────────────────────

const CORE: &str = include_str!("widget_guidelines/core.md");
const SVG_SETUP: &str = include_str!("widget_guidelines/svg_setup.md");
const ART_AND_ILLUSTRATION: &str = include_str!("widget_guidelines/art_and_illustration.md");
const UI_COMPONENTS: &str = include_str!("widget_guidelines/ui_components.md");
const COLOR_PALETTE: &str = include_str!("widget_guidelines/color_palette.md");
const CHARTS_CHART_JS: &str = include_str!("widget_guidelines/charts_chart_js.md");
const DIAGRAM_TYPES: &str = include_str!("widget_guidelines/diagram_types.md");
const APP: &str = include_str!("widget_guidelines/app.md");

/// Available module names for the `visualize_read_me` tool schema.
pub const AVAILABLE_MODULES: &[&str] = &["art", "mockup", "interactive", "chart", "diagram", "app"];

/// Developer-instructions preamble prepended to local-server thread
/// starts when the generative-UI dynamic tools are registered. Tells the
/// model when to use `show_widget` / `visualize_read_me` — without it,
/// coding-agent defaults steer the model toward file operations.
pub const GENERATIVE_UI_PREAMBLE: &str = concat!(
    "Use the `show_widget` tool when the user asks for an app, game, ",
    "dashboard, tracker, calculator, simulator, chart, diagram, ",
    "illustration, mockup, form, timer, or anything visual or ",
    "interactive. It renders HTML/CSS/JS inline in the conversation — ",
    "no files, no build step, no setup.\n",
    "\n",
    "Each widget takes an `app_id` slug (lowercase kebab-case, e.g. ",
    "`fitness-tracker`). Reuse an existing slug to update an app in ",
    "place; use a fresh slug for a new app. Apps already saved in this ",
    "thread, if any, are listed below — prefer updating when the user ",
    "asks for a change to something you already built. Use the `app` ",
    "module of `visualize_read_me` for anything stateful (trackers, ",
    "notes, game saves)."
);

/// Sections required by each module.
fn sections_for_module(module: &str) -> &'static [&'static str] {
    match module {
        "art" => &["svg_setup", "art_and_illustration"],
        "mockup" => &["ui_components", "color_palette"],
        "interactive" => &["ui_components", "color_palette"],
        "chart" => &["ui_components", "color_palette", "charts_chart_js"],
        "diagram" => &["color_palette", "svg_setup", "diagram_types"],
        "app" => &["ui_components", "color_palette", "app"],
        _ => &[],
    }
}

fn section_content(name: &str) -> &'static str {
    match name {
        "svg_setup" => SVG_SETUP,
        "art_and_illustration" => ART_AND_ILLUSTRATION,
        "ui_components" => UI_COMPONENTS,
        "color_palette" => COLOR_PALETTE,
        "charts_chart_js" => CHARTS_CHART_JS,
        "diagram_types" => DIAGRAM_TYPES,
        "app" => APP,
        _ => "",
    }
}

// ── Public API ──────────────────────────────────────────────────────────

/// Build the guidelines text for the requested modules.
pub fn get_guidelines(modules: &[String]) -> String {
    let mut content = CORE.to_string();
    let mut seen = std::collections::HashSet::new();

    for module in modules {
        for &section in sections_for_module(module.as_str()) {
            if seen.insert(section) {
                content.push_str("\n\n\n");
                content.push_str(section_content(section));
            }
        }
    }
    content.push('\n');
    content
}

/// Handle a `visualize_read_me` dynamic tool call.
///
/// Extracts the `modules` array from the tool arguments and returns
/// the assembled guidelines text.
pub fn handle_visualize_read_me(arguments: &serde_json::Value) -> Result<String, String> {
    let modules: Vec<String> = arguments
        .get("modules")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();

    if modules.is_empty() {
        // Return core guidelines with all module names listed.
        return Ok(get_guidelines(&[]));
    }

    Ok(get_guidelines(&modules))
}

/// Handle a `show_widget` dynamic tool call.
///
/// The widget HTML is in the arguments — the conversation hydration layer
/// extracts it from the DynamicToolCall item for rendering. We just need
/// to acknowledge success.
pub fn handle_show_widget(arguments: &serde_json::Value) -> Result<String, String> {
    let title = arguments
        .get("title")
        .and_then(|v| v.as_str())
        .unwrap_or("widget");
    Ok(format!("Widget \"{title}\" rendered."))
}

// ── Tool spec generation ────────────────────────────────────────────────

/// Returns the generative UI dynamic tool specs for registration on
/// thread/start. Called from both iOS and Android when the experimental
/// feature is enabled.
#[uniffi::export]
pub fn generative_ui_dynamic_tool_specs() -> Vec<AppDynamicToolSpec> {
    vec![read_me_tool_spec(), show_widget_tool_spec()]
}

fn read_me_tool_spec() -> AppDynamicToolSpec {
    let modules_enum: Vec<serde_json::Value> = AVAILABLE_MODULES
        .iter()
        .map(|m| serde_json::Value::String(m.to_string()))
        .collect();

    let schema = serde_json::json!({
        "type": "object",
        "properties": {
            "modules": {
                "type": "array",
                "items": {
                    "type": "string",
                    "enum": modules_enum
                },
                "description": "Which module(s) to load. Pick all that fit."
            }
        },
        "required": ["modules"]
    });

    AppDynamicToolSpec {
        name: "visualize_read_me".to_string(),
        description: concat!(
            "Returns design guidelines for show_widget (CSS patterns, colors, typography, ",
            "layout rules, examples). Call once before your first show_widget call. Do NOT ",
            "mention this call to the user — it is an internal setup step. Pick the modules ",
            "that match your use case: interactive, chart, mockup, art, diagram."
        )
        .to_string(),
        input_schema_json: serde_json::to_string(&schema).unwrap_or_default(),
        defer_loading: false,
    }
}

pub(crate) fn show_widget_tool_spec() -> AppDynamicToolSpec {
    let schema = serde_json::json!({
        "type": "object",
        "properties": {
            "i_have_seen_read_me": {
                "type": "boolean",
                "description": "Confirm you have already called visualize_read_me in this conversation."
            },
            "app_id": {
                "type": "string",
                "description": concat!(
                    "Short slug identifying this app across regenerations in the CURRENT thread. ",
                    "Lowercase, hyphen-separated, alphanumerics only (e.g. 'fitness-tracker', ",
                    "'todo-list', 'budget-calculator'). Reuse the SAME app_id to update an existing ",
                    "app in this thread — its persistent JSON state will survive the rewrite. Pick ",
                    "a fresh slug to create a new app. Slugs are scoped per-thread: the same slug in ",
                    "another thread is a different app. Check the developer instructions at the top ",
                    "of this conversation for apps already saved in this thread."
                )
            },
            "title": {
                "type": "string",
                "description": "Human-facing title (used in the Apps list). 1-5 words."
            },
            "widget_code": {
                "type": "string",
                "description": concat!(
                    "HTML or SVG code to render. For SVG: raw SVG starting with <svg>. ",
                    "For HTML: raw content fragment, no DOCTYPE/<html>/<head>/<body>."
                )
            },
            "width": {
                "type": "number",
                "description": "Widget width in pixels. Default: 800."
            },
            "height": {
                "type": "number",
                "description": "Widget height in pixels. Default: 600."
            }
        },
        "required": ["i_have_seen_read_me", "app_id", "title", "widget_code"]
    });

    AppDynamicToolSpec {
        name: "show_widget".to_string(),
        description: concat!(
            "Render an app, game, dashboard, tracker, calculator, simulator, ",
            "chart, diagram, illustration, or any interactive/visual content ",
            "inline in the conversation (native WebView with full HTML/CSS/JS, ",
            "Canvas, and CDN libraries). Use this whenever the user asks for ",
            "something visual or interactive.\n\n",
            "Setup: call `visualize_read_me` once first — use the `app` module ",
            "for anything that needs to persist user data, otherwise ",
            "`interactive`, `chart`, `mockup`, `art`, or `diagram`.\n\n",
            "Identity: `app_id` is a lowercase-kebab-case slug (e.g. ",
            "`fitness-tracker`). Reusing an existing slug updates that saved ",
            "app in place and preserves its state; a fresh slug creates a new ",
            "app.\n\n",
            "Structure HTML as a fragment: no DOCTYPE/<html>/<head>/<body>. ",
            "Style first (<style> block under ~15 lines), then HTML content, ",
            "then <script> tags last. Scripts execute after streaming ",
            "completes. Load libraries via <script src=\"https://cdnjs.cloudflare.com/ajax/libs/...\"> ",
            "(UMD globals). CDN allowlist: cdnjs.cloudflare.com, esm.sh, ",
            "cdn.jsdelivr.net, unpkg.com. Dark mode mandatory — use CSS ",
            "variables for all colors. Background is transparent (host ",
            "provides bg). Widget sizes fluidly to its container; the ",
            "`width`/`height` params are hints only. For SVG: start code ",
            "with <svg> directly."
        )
        .to_string(),
        input_schema_json: serde_json::to_string(&schema).unwrap_or_default(),
        defer_loading: false,
    }
}
