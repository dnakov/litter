//! Parser for plugin references embedded in titles and message text.
//!
//! Upstream writes plugin references in a markdown-link-like format:
//!
//!     [@Display Name](plugin://plugin-name@marketplace)
//!
//! Example titles seen in the wild:
//!   [@Computer Use](plugin://computer-use@openai-bundled)
//!   open [@Codex](plugin://computer-use@openai-bundled)
//!
//! We parse the input into a `Vec<TitleSegment>` so mobile platforms can
//! render pills inline without repeating the regex/match logic.

use std::sync::LazyLock;

use regex::Regex;

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum TitleSegment {
    Text {
        text: String,
    },
    PluginRef {
        display_name: String,
        plugin_name: String,
        marketplace: String,
    },
}

static PLUGIN_REF_RE: LazyLock<Regex> = LazyLock::new(|| {
    // [@<display>](plugin://<name>@<marketplace>)
    //   - display: any run of non-']' characters
    //   - name:    any run of non-'@' and non-')' characters
    //   - marketplace: any run of non-')' characters
    Regex::new(r"\[@([^\]]+)\]\(plugin://([^@)]+)@([^)]+)\)")
        .expect("plugin ref regex must compile")
});

/// Parse plugin references out of `input` into a flat list of segments.
///
/// Adjacent plain-text runs are collapsed into a single `Text` segment.
/// If the input contains no references, the result is a single `Text` with
/// the entire string. An empty string returns an empty vec.
#[uniffi::export]
pub fn parse_plugin_refs(input: String) -> Vec<TitleSegment> {
    if input.is_empty() {
        return Vec::new();
    }

    let mut segments = Vec::new();
    let mut cursor = 0usize;

    for cap in PLUGIN_REF_RE.captures_iter(&input) {
        let whole = cap.get(0).expect("match has group 0");
        if whole.start() > cursor {
            let text = input[cursor..whole.start()].to_string();
            if !text.is_empty() {
                segments.push(TitleSegment::Text { text });
            }
        }

        let display_name = cap
            .get(1)
            .map(|m| m.as_str().trim().to_string())
            .unwrap_or_default();
        let plugin_name = cap
            .get(2)
            .map(|m| m.as_str().trim().to_string())
            .unwrap_or_default();
        let marketplace = cap
            .get(3)
            .map(|m| m.as_str().trim().to_string())
            .unwrap_or_default();

        segments.push(TitleSegment::PluginRef {
            display_name,
            plugin_name,
            marketplace,
        });

        cursor = whole.end();
    }

    if cursor < input.len() {
        let text = input[cursor..].to_string();
        if !text.is_empty() {
            segments.push(TitleSegment::Text { text });
        }
    }

    if segments.is_empty() {
        segments.push(TitleSegment::Text { text: input });
    }

    segments
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_text_becomes_single_text_segment() {
        assert_eq!(
            parse_plugin_refs("hello world".to_string()),
            vec![TitleSegment::Text {
                text: "hello world".to_string()
            }]
        );
    }

    #[test]
    fn empty_input_returns_empty() {
        assert!(parse_plugin_refs(String::new()).is_empty());
    }

    #[test]
    fn single_ref() {
        let got = parse_plugin_refs("[@Computer Use](plugin://computer-use@openai-bundled)".into());
        assert_eq!(
            got,
            vec![TitleSegment::PluginRef {
                display_name: "Computer Use".into(),
                plugin_name: "computer-use".into(),
                marketplace: "openai-bundled".into(),
            }]
        );
    }

    #[test]
    fn ref_with_prefix_and_suffix() {
        let got =
            parse_plugin_refs("open [@Codex](plugin://computer-use@openai-bundled) now".into());
        assert_eq!(
            got,
            vec![
                TitleSegment::Text {
                    text: "open ".into()
                },
                TitleSegment::PluginRef {
                    display_name: "Codex".into(),
                    plugin_name: "computer-use".into(),
                    marketplace: "openai-bundled".into(),
                },
                TitleSegment::Text {
                    text: " now".into()
                },
            ]
        );
    }

    #[test]
    fn multiple_refs() {
        let got = parse_plugin_refs("use [@A](plugin://a@m1) then [@B](plugin://b@m2)".into());
        assert_eq!(got.len(), 4);
        assert!(
            matches!(&got[1], TitleSegment::PluginRef { plugin_name, .. } if plugin_name == "a")
        );
        assert!(
            matches!(&got[3], TitleSegment::PluginRef { plugin_name, .. } if plugin_name == "b")
        );
    }

    #[test]
    fn malformed_markdown_stays_text() {
        let got = parse_plugin_refs("[@oops](not-a-plugin://x)".into());
        assert_eq!(
            got,
            vec![TitleSegment::Text {
                text: "[@oops](not-a-plugin://x)".into()
            }]
        );
    }
}
