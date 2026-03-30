//! Progressive message hydration and LRU caching.
//!
//! Handles paginated message loading (48 initial, 96-chunk), LRU cache
//! with revision-keyed entries, and inline base64 image extraction.

use base64::Engine;
use lru::LruCache;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::fmt;
use std::num::NonZeroUsize;
use std::sync::LazyLock;
use std::sync::atomic::{AtomicU64, Ordering};

use crate::parser::ToolCallCard;

// ---------------------------------------------------------------------------
// MessageHydrator — progressive loading configuration
// ---------------------------------------------------------------------------

/// Controls paginated / progressive message loading.
pub struct MessageHydrator {
    initial_load_count: usize,
    chunk_size: usize,
}

impl MessageHydrator {
    /// Create with default sizes: 48 initial, 96 per chunk.
    pub fn new() -> Self {
        Self {
            initial_load_count: 48,
            chunk_size: 96,
        }
    }

    /// Create with custom sizes.
    pub fn with_sizes(initial: usize, chunk: usize) -> Self {
        Self {
            initial_load_count: initial,
            chunk_size: chunk,
        }
    }

    pub fn initial_load_count(&self) -> usize {
        self.initial_load_count
    }

    pub fn chunk_size(&self) -> usize {
        self.chunk_size
    }
}

impl Default for MessageHydrator {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// CacheKey
// ---------------------------------------------------------------------------

/// Uniquely identifies a specific revision of a message for caching.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CacheKey {
    pub message_id: String,
    pub revision_token: String,
    pub server_id: String,
    pub agent_directory_version: u32,
}

impl fmt::Display for CacheKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}:{}:{}:{}",
            self.message_id, self.revision_token, self.server_id, self.agent_directory_version
        )
    }
}

// ---------------------------------------------------------------------------
// MessageSegment
// ---------------------------------------------------------------------------

/// A parsed segment of assistant message content.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub enum MessageSegment {
    Text(String),
    InlineImage {
        data: Vec<u8>,
        mime_type: String,
    },
    CodeBlock {
        language: Option<String>,
        code: String,
    },
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum AppMessageSegment {
    Text {
        text: String,
    },
    InlineImage {
        data: Vec<u8>,
        mime_type: String,
    },
    CodeBlock {
        language: Option<String>,
        code: String,
    },
}

impl From<MessageSegment> for AppMessageSegment {
    fn from(value: MessageSegment) -> Self {
        match value {
            MessageSegment::Text(text) => Self::Text { text },
            MessageSegment::InlineImage { data, mime_type } => {
                Self::InlineImage { data, mime_type }
            }
            MessageSegment::CodeBlock { language, code } => Self::CodeBlock { language, code },
        }
    }
}

// ---------------------------------------------------------------------------
// CachedMessage
// ---------------------------------------------------------------------------

/// A fully parsed and cached message, ready for rendering.
#[derive(Debug, Clone, Serialize)]
pub struct CachedMessage {
    pub segments: Vec<MessageSegment>,
    pub tool_calls: Vec<ToolCallCard>,
}

// ---------------------------------------------------------------------------
// MessageCache — LRU with trim-down semantics
// ---------------------------------------------------------------------------

/// LRU message cache that trims down to `trim_to` when `max_entries` is exceeded.
pub struct MessageCache {
    cache: LruCache<String, CachedMessage>,
    max_entries: usize,
    trim_to: usize,
}

impl MessageCache {
    /// Create with defaults: max 1024 entries, trim to 768.
    pub fn new() -> Self {
        Self::with_capacity(1024, 768)
    }

    /// Create with custom capacity limits.
    pub fn with_capacity(max: usize, trim_to: usize) -> Self {
        // LruCache needs a NonZeroUsize cap. We use max + 1 so that
        // the LRU itself never auto-evicts before our trim logic runs.
        let lru_cap = NonZeroUsize::new(max + 1).expect("max must be > 0");
        Self {
            cache: LruCache::new(lru_cap),
            max_entries: max,
            trim_to,
        }
    }

    /// Look up a cached message, promoting it in the LRU order.
    pub fn get(&mut self, key: &CacheKey) -> Option<&CachedMessage> {
        let key_str = key.to_string();
        self.cache.get(&key_str)
    }

    /// Insert a message into the cache, trimming if the cache exceeds capacity.
    pub fn insert(&mut self, key: CacheKey, message: CachedMessage) {
        let key_str = key.to_string();
        self.cache.put(key_str, message);
        self.trim_if_needed();
    }

    /// Remove all entries for a given message_id (any revision).
    pub fn invalidate(&mut self, message_id: &str) {
        let prefix = format!("{}:", message_id);
        let keys_to_remove: Vec<String> = self
            .cache
            .iter()
            .filter(|(k, _)| k.starts_with(&prefix))
            .map(|(k, _)| k.clone())
            .collect();
        for k in keys_to_remove {
            self.cache.pop(&k);
        }
    }

    /// Remove all entries.
    pub fn clear(&mut self) {
        self.cache.clear();
    }

    /// Number of entries currently in the cache.
    pub fn len(&self) -> usize {
        self.cache.len()
    }

    /// Whether the cache is empty.
    pub fn is_empty(&self) -> bool {
        self.cache.is_empty()
    }

    /// When we exceed `max_entries`, pop the least-recently-used entries
    /// until we are at `trim_to`.
    fn trim_if_needed(&mut self) {
        if self.cache.len() > self.max_entries {
            while self.cache.len() > self.trim_to {
                self.cache.pop_lru();
            }
        }
    }
}

impl Default for MessageCache {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// Inline image extraction regex
// ---------------------------------------------------------------------------

/// Matches markdown inline images with data URIs:
///   ![alt](data:image/TYPE;base64,DATA)
/// Also matches bare data URIs (not inside markdown image syntax):
///   data:image/TYPE;base64,DATA
static INLINE_IMAGE_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"!\[[^\]]*\]\(data:image/([^;]+);base64,([A-Za-z0-9+/=\s]+)\)")
        .expect("invalid inline image regex")
});

/// Matches bare data URIs that are not part of markdown image syntax.
static BARE_DATA_URI_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"data:image/([^;]+);base64,([A-Za-z0-9+/=]+)").expect("invalid bare data URI regex")
});

// ---------------------------------------------------------------------------
// Segment extraction
// ---------------------------------------------------------------------------

/// Try to decode an inline image from a regex capture (groups 1=mime, 2=base64).
fn decode_image_capture(cap: &regex::Captures<'_>) -> Option<(String, Vec<u8>)> {
    let mime_suffix = cap.get(1)?.as_str();
    let b64_data = cap.get(2)?.as_str();
    let cleaned: String = b64_data.chars().filter(|c| !c.is_whitespace()).collect();
    let engine = base64::engine::general_purpose::STANDARD;
    let bytes = engine.decode(&cleaned).ok()?;
    Some((format!("image/{}", mime_suffix), bytes))
}

/// Find all code fence spans in `text` using a line-based scan.
/// Returns `(byte_start, byte_end, language, code)` tuples.
fn find_code_fences(text: &str) -> Vec<(usize, usize, Option<String>, String)> {
    let mut results = Vec::new();
    let mut fence_char: Option<char> = None;
    let mut fence_len: usize = 0;
    let mut fence_start: usize = 0;
    let mut fence_language = String::new();
    let mut code_lines: Vec<&str> = Vec::new();
    let mut in_fence = false;

    for (line_start, line) in line_byte_offsets(text) {
        let trimmed = line.trim();

        if in_fence {
            // Check if this is the closing fence
            if let Some(fc) = fence_char {
                let close_len = trimmed.chars().take_while(|&c| c == fc).count();
                if close_len >= fence_len && trimmed[fc.len_utf8() * close_len..].trim().is_empty()
                {
                    let line_end = line_start + line.len();
                    let code = code_lines.join("\n");
                    let language = if fence_language.is_empty() {
                        None
                    } else {
                        Some(fence_language.clone())
                    };
                    results.push((fence_start, line_end, language, code));
                    in_fence = false;
                    fence_char = None;
                    code_lines.clear();
                    continue;
                }
            }
            code_lines.push(line);
        } else {
            // Check if this line opens a fence
            let first_char = trimmed.chars().next();
            if let Some(fc) = first_char {
                if fc == '`' || fc == '~' {
                    let fl = trimmed.chars().take_while(|&c| c == fc).count();
                    if fl >= 3 {
                        fence_char = Some(fc);
                        fence_len = fl;
                        fence_start = line_start;
                        fence_language = trimmed[fc.len_utf8() * fl..].trim().to_owned();
                        in_fence = true;
                        code_lines.clear();
                        continue;
                    }
                }
            }
        }
    }

    results
}

/// Iterate over lines with their byte offset in the original string.
fn line_byte_offsets(text: &str) -> Vec<(usize, &str)> {
    let mut result = Vec::new();
    let mut offset = 0;
    for line in text.split('\n') {
        result.push((offset, line));
        offset += line.len() + 1; // +1 for the '\n'
    }
    result
}

/// Extract inline base64 images and code blocks from message text,
/// splitting into typed segments.
///
/// Processing order:
/// 1. Find all inline image matches and code fence spans
/// 2. Sort by position
/// 3. Emit Text / InlineImage / CodeBlock segments in order
pub fn extract_message_segments(text: &str) -> Vec<MessageSegment> {
    if text.is_empty() {
        return Vec::new();
    }

    // Collect all "spans" (start, end, segment) sorted by start position.
    let mut spans: Vec<(usize, usize, MessageSegment)> = Vec::new();

    // Markdown inline images: ![...](data:image/...;base64,...)
    for cap in INLINE_IMAGE_RE.captures_iter(text) {
        let m = cap.get(0).unwrap();
        if let Some((mime_type, bytes)) = decode_image_capture(&cap) {
            spans.push((
                m.start(),
                m.end(),
                MessageSegment::InlineImage {
                    data: bytes,
                    mime_type,
                },
            ));
        }
    }

    // Bare data URIs — only add if they don't overlap with markdown image matches
    for cap in BARE_DATA_URI_RE.captures_iter(text) {
        let m = cap.get(0).unwrap();
        let overlaps = spans.iter().any(|(s, e, _)| m.start() < *e && m.end() > *s);
        if overlaps {
            continue;
        }
        if let Some((mime_type, bytes)) = decode_image_capture(&cap) {
            spans.push((
                m.start(),
                m.end(),
                MessageSegment::InlineImage {
                    data: bytes,
                    mime_type,
                },
            ));
        }
    }

    // Code fences (line-based scan)
    for (start, end, language, code) in find_code_fences(text) {
        let overlaps = spans.iter().any(|(s, e, _)| start < *e && end > *s);
        if overlaps {
            continue;
        }
        spans.push((start, end, MessageSegment::CodeBlock { language, code }));
    }

    if spans.is_empty() {
        return vec![MessageSegment::Text(text.to_owned())];
    }

    spans.sort_by_key(|(start, _, _)| *start);

    // Remove overlapping spans (keep earlier ones)
    let mut deduped: Vec<(usize, usize, MessageSegment)> = Vec::new();
    for span in spans {
        if let Some(last) = deduped.last() {
            if span.0 < last.1 {
                continue;
            }
        }
        deduped.push(span);
    }

    let mut segments: Vec<MessageSegment> = Vec::new();
    let mut cursor = 0;

    for (start, end, segment) in deduped {
        if cursor < start {
            let preceding = text[cursor..start].trim();
            if !preceding.is_empty() {
                segments.push(MessageSegment::Text(preceding.to_owned()));
            }
        }
        segments.push(segment);
        cursor = end;
    }

    // Trailing text
    if cursor < text.len() {
        let remaining = text[cursor..].trim();
        if !remaining.is_empty() {
            segments.push(MessageSegment::Text(remaining.to_owned()));
        }
    }

    if segments.is_empty() {
        vec![MessageSegment::Text(text.to_owned())]
    } else {
        segments
    }
}

// ---------------------------------------------------------------------------
// FollowScrollTracker
// ---------------------------------------------------------------------------

/// Monotonically incrementing token used by the UI to decide whether
/// to auto-scroll to the bottom of the conversation timeline.
pub struct FollowScrollTracker {
    token: AtomicU64,
}

impl FollowScrollTracker {
    pub fn new() -> Self {
        Self {
            token: AtomicU64::new(0),
        }
    }

    /// Return the current token value.
    pub fn current(&self) -> u64 {
        self.token.load(Ordering::SeqCst)
    }

    /// Increment and return the new token value.
    pub fn increment(&self) -> u64 {
        self.token.fetch_add(1, Ordering::SeqCst) + 1
    }
}

impl Default for FollowScrollTracker {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // -- MessageHydrator --

    #[test]
    fn test_hydrator_defaults() {
        let h = MessageHydrator::new();
        assert_eq!(h.initial_load_count(), 48);
        assert_eq!(h.chunk_size(), 96);
    }

    #[test]
    fn test_hydrator_custom() {
        let h = MessageHydrator::with_sizes(10, 20);
        assert_eq!(h.initial_load_count(), 10);
        assert_eq!(h.chunk_size(), 20);
    }

    #[test]
    fn test_hydrator_default_trait() {
        let h = MessageHydrator::default();
        assert_eq!(h.initial_load_count(), 48);
    }

    // -- CacheKey --

    #[test]
    fn test_cache_key_display() {
        let key = CacheKey {
            message_id: "msg-1".to_owned(),
            revision_token: "rev-abc".to_owned(),
            server_id: "srv-1".to_owned(),
            agent_directory_version: 3,
        };
        assert_eq!(key.to_string(), "msg-1:rev-abc:srv-1:3");
    }

    #[test]
    fn test_cache_key_equality() {
        let a = CacheKey {
            message_id: "m1".into(),
            revision_token: "r1".into(),
            server_id: "s1".into(),
            agent_directory_version: 1,
        };
        let b = CacheKey {
            message_id: "m1".into(),
            revision_token: "r1".into(),
            server_id: "s1".into(),
            agent_directory_version: 1,
        };
        assert_eq!(a, b);
    }

    #[test]
    fn test_cache_key_inequality_revision() {
        let a = CacheKey {
            message_id: "m1".into(),
            revision_token: "r1".into(),
            server_id: "s1".into(),
            agent_directory_version: 1,
        };
        let b = CacheKey {
            message_id: "m1".into(),
            revision_token: "r2".into(),
            server_id: "s1".into(),
            agent_directory_version: 1,
        };
        assert_ne!(a, b);
    }

    // -- MessageCache basic operations --

    fn make_key(msg_id: &str, rev: &str) -> CacheKey {
        CacheKey {
            message_id: msg_id.to_owned(),
            revision_token: rev.to_owned(),
            server_id: "srv".to_owned(),
            agent_directory_version: 1,
        }
    }

    fn make_cached(text: &str) -> CachedMessage {
        CachedMessage {
            segments: vec![MessageSegment::Text(text.to_owned())],
            tool_calls: vec![],
        }
    }

    #[test]
    fn test_cache_insert_and_get() {
        let mut cache = MessageCache::new();
        let key = make_key("m1", "r1");
        cache.insert(key.clone(), make_cached("hello"));
        assert_eq!(cache.len(), 1);
        assert!(!cache.is_empty());

        let got = cache.get(&key).unwrap();
        assert_eq!(got.segments.len(), 1);
        match &got.segments[0] {
            MessageSegment::Text(t) => assert_eq!(t, "hello"),
            _ => panic!("expected Text"),
        }
    }

    #[test]
    fn test_cache_miss() {
        let mut cache = MessageCache::new();
        let key = make_key("m1", "r1");
        assert!(cache.get(&key).is_none());
    }

    #[test]
    fn test_cache_clear() {
        let mut cache = MessageCache::new();
        cache.insert(make_key("m1", "r1"), make_cached("a"));
        cache.insert(make_key("m2", "r1"), make_cached("b"));
        assert_eq!(cache.len(), 2);

        cache.clear();
        assert_eq!(cache.len(), 0);
        assert!(cache.is_empty());
    }

    #[test]
    fn test_cache_invalidate_by_message_id() {
        let mut cache = MessageCache::new();
        cache.insert(make_key("m1", "r1"), make_cached("v1"));
        cache.insert(make_key("m1", "r2"), make_cached("v2"));
        cache.insert(make_key("m2", "r1"), make_cached("other"));
        assert_eq!(cache.len(), 3);

        cache.invalidate("m1");
        assert_eq!(cache.len(), 1);
        assert!(cache.get(&make_key("m1", "r1")).is_none());
        assert!(cache.get(&make_key("m1", "r2")).is_none());
        assert!(cache.get(&make_key("m2", "r1")).is_some());
    }

    // -- LRU eviction --

    #[test]
    fn test_lru_eviction_trims_to_target() {
        // max=8, trim_to=4
        let mut cache = MessageCache::with_capacity(8, 4);

        // Insert 9 items → exceeds max of 8, should trim to 4
        for i in 0..9 {
            cache.insert(
                make_key(&format!("m{}", i), "r1"),
                make_cached(&format!("v{}", i)),
            );
        }

        assert_eq!(cache.len(), 4);

        // The most recently inserted items should survive
        assert!(cache.get(&make_key("m8", "r1")).is_some());
        assert!(cache.get(&make_key("m7", "r1")).is_some());
        assert!(cache.get(&make_key("m6", "r1")).is_some());
        assert!(cache.get(&make_key("m5", "r1")).is_some());

        // Older items should be evicted
        assert!(cache.get(&make_key("m0", "r1")).is_none());
        assert!(cache.get(&make_key("m1", "r1")).is_none());
        assert!(cache.get(&make_key("m2", "r1")).is_none());
        assert!(cache.get(&make_key("m3", "r1")).is_none());
        assert!(cache.get(&make_key("m4", "r1")).is_none());
    }

    #[test]
    fn test_lru_eviction_1025_trims_to_768() {
        let mut cache = MessageCache::new(); // max 1024, trim_to 768

        for i in 0..1025 {
            cache.insert(
                make_key(&format!("msg-{}", i), "r1"),
                make_cached(&format!("value-{}", i)),
            );
        }

        assert_eq!(cache.len(), 768);

        // Most recent should survive
        assert!(cache.get(&make_key("msg-1024", "r1")).is_some());
        assert!(cache.get(&make_key("msg-1023", "r1")).is_some());

        // Oldest should be evicted
        assert!(cache.get(&make_key("msg-0", "r1")).is_none());
        assert!(cache.get(&make_key("msg-1", "r1")).is_none());
    }

    #[test]
    fn test_lru_access_order_promotion() {
        // max=4, trim_to=2
        let mut cache = MessageCache::with_capacity(4, 2);

        // Insert 4 items
        cache.insert(make_key("m0", "r1"), make_cached("v0"));
        cache.insert(make_key("m1", "r1"), make_cached("v1"));
        cache.insert(make_key("m2", "r1"), make_cached("v2"));
        cache.insert(make_key("m3", "r1"), make_cached("v3"));

        // Access m0 to promote it (most recently used)
        assert!(cache.get(&make_key("m0", "r1")).is_some());

        // Insert one more → triggers trim from 5 → 2
        cache.insert(make_key("m4", "r1"), make_cached("v4"));

        assert_eq!(cache.len(), 2);

        // m4 (just inserted) and m0 (recently accessed) should survive
        assert!(cache.get(&make_key("m4", "r1")).is_some());
        assert!(cache.get(&make_key("m0", "r1")).is_some());

        // m1, m2, m3 should be evicted
        assert!(cache.get(&make_key("m1", "r1")).is_none());
        assert!(cache.get(&make_key("m2", "r1")).is_none());
        assert!(cache.get(&make_key("m3", "r1")).is_none());
    }

    // -- extract_message_segments --

    #[test]
    fn test_extract_plain_text() {
        let segs = extract_message_segments("Hello, world!");
        assert_eq!(segs.len(), 1);
        assert_eq!(segs[0], MessageSegment::Text("Hello, world!".to_owned()));
    }

    #[test]
    fn test_extract_empty() {
        let segs = extract_message_segments("");
        assert!(segs.is_empty());
    }

    #[test]
    fn test_extract_code_block() {
        let text = "Before\n```python\nprint('hi')\n```\nAfter";
        let segs = extract_message_segments(text);

        assert_eq!(segs.len(), 3);
        assert_eq!(segs[0], MessageSegment::Text("Before".to_owned()));
        assert_eq!(
            segs[1],
            MessageSegment::CodeBlock {
                language: Some("python".to_owned()),
                code: "print('hi')".to_owned(),
            }
        );
        assert_eq!(segs[2], MessageSegment::Text("After".to_owned()));
    }

    #[test]
    fn test_extract_code_block_no_language() {
        let text = "```\nsome code\n```";
        let segs = extract_message_segments(text);

        assert_eq!(segs.len(), 1);
        assert_eq!(
            segs[0],
            MessageSegment::CodeBlock {
                language: None,
                code: "some code".to_owned(),
            }
        );
    }

    #[test]
    fn test_extract_inline_image_markdown() {
        // Create a small 1x1 red PNG as base64
        let png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==";
        let text = format!(
            "Before image ![alt](data:image/png;base64,{}) after image",
            png_b64
        );

        let segs = extract_message_segments(&text);
        assert_eq!(segs.len(), 3);

        assert_eq!(segs[0], MessageSegment::Text("Before image".to_owned()));

        match &segs[1] {
            MessageSegment::InlineImage { data, mime_type } => {
                assert_eq!(mime_type, "image/png");
                assert!(!data.is_empty());
                // PNG magic bytes
                assert_eq!(&data[..4], &[0x89, 0x50, 0x4E, 0x47]);
            }
            other => panic!("Expected InlineImage, got {:?}", other),
        }

        assert_eq!(segs[2], MessageSegment::Text("after image".to_owned()));
    }

    #[test]
    fn test_extract_inline_image_bare_data_uri() {
        let png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==";
        let text = format!("Look at this: data:image/png;base64,{} cool", png_b64);

        let segs = extract_message_segments(&text);
        // Should have text before, image, text after
        assert!(segs.len() >= 2);

        let has_image = segs
            .iter()
            .any(|s| matches!(s, MessageSegment::InlineImage { .. }));
        assert!(has_image);
    }

    #[test]
    fn test_extract_jpeg_mime_type() {
        // Minimal JPEG-like base64 (won't be a valid JPEG but tests mime extraction)
        let text = "![photo](data:image/jpeg;base64,/9j/4AAQSkZJRg==)";
        let segs = extract_message_segments(text);

        let image_seg = segs
            .iter()
            .find(|s| matches!(s, MessageSegment::InlineImage { .. }));
        assert!(image_seg.is_some());

        match image_seg.unwrap() {
            MessageSegment::InlineImage { mime_type, .. } => {
                assert_eq!(mime_type, "image/jpeg");
            }
            _ => unreachable!(),
        }
    }

    #[test]
    fn test_extract_mixed_content() {
        let png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==";
        let text = format!(
            "# Heading\n\nSome text\n\n![img](data:image/png;base64,{})\n\n```rust\nfn main() {{}}\n```\n\nTrailing text",
            png_b64
        );

        let segs = extract_message_segments(&text);

        let text_count = segs
            .iter()
            .filter(|s| matches!(s, MessageSegment::Text(_)))
            .count();
        let image_count = segs
            .iter()
            .filter(|s| matches!(s, MessageSegment::InlineImage { .. }))
            .count();
        let code_count = segs
            .iter()
            .filter(|s| matches!(s, MessageSegment::CodeBlock { .. }))
            .count();

        assert!(text_count >= 1, "should have at least one text segment");
        assert_eq!(image_count, 1, "should have exactly one image");
        assert_eq!(code_count, 1, "should have exactly one code block");
    }

    #[test]
    fn test_extract_invalid_base64_skipped() {
        let text = "![bad](data:image/png;base64,!!!not-valid-base64!!!)";
        let segs = extract_message_segments(text);
        // Invalid base64 should not produce an InlineImage segment
        let has_image = segs
            .iter()
            .any(|s| matches!(s, MessageSegment::InlineImage { .. }));
        assert!(!has_image);
    }

    #[test]
    fn test_extract_multiple_images() {
        let png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==";
        let text = format!(
            "![a](data:image/png;base64,{}) middle ![b](data:image/png;base64,{})",
            png_b64, png_b64
        );

        let segs = extract_message_segments(&text);
        let image_count = segs
            .iter()
            .filter(|s| matches!(s, MessageSegment::InlineImage { .. }))
            .count();
        assert_eq!(image_count, 2);
    }

    #[test]
    fn test_extract_base64_with_whitespace() {
        // base64 with embedded whitespace should still decode
        let png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAf\nFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==";
        let text = format!("![img](data:image/png;base64,{})", png_b64);

        let segs = extract_message_segments(&text);
        let has_image = segs
            .iter()
            .any(|s| matches!(s, MessageSegment::InlineImage { .. }));
        assert!(has_image, "whitespace in base64 should still decode");
    }

    // -- FollowScrollTracker --

    #[test]
    fn test_follow_scroll_initial() {
        let tracker = FollowScrollTracker::new();
        assert_eq!(tracker.current(), 0);
    }

    #[test]
    fn test_follow_scroll_increment() {
        let tracker = FollowScrollTracker::new();
        assert_eq!(tracker.increment(), 1);
        assert_eq!(tracker.increment(), 2);
        assert_eq!(tracker.current(), 2);
    }

    #[test]
    fn test_follow_scroll_default() {
        let tracker = FollowScrollTracker::default();
        assert_eq!(tracker.current(), 0);
    }

    // -- Cache key matching --

    #[test]
    fn test_cache_key_same_message_different_server() {
        let mut cache = MessageCache::new();
        let key_a = CacheKey {
            message_id: "m1".into(),
            revision_token: "r1".into(),
            server_id: "server-a".into(),
            agent_directory_version: 1,
        };
        let key_b = CacheKey {
            message_id: "m1".into(),
            revision_token: "r1".into(),
            server_id: "server-b".into(),
            agent_directory_version: 1,
        };

        cache.insert(key_a.clone(), make_cached("from server A"));
        cache.insert(key_b.clone(), make_cached("from server B"));

        assert_eq!(cache.len(), 2);

        let a = cache.get(&key_a).unwrap();
        match &a.segments[0] {
            MessageSegment::Text(t) => assert_eq!(t, "from server A"),
            _ => panic!("expected text"),
        }

        let b = cache.get(&key_b).unwrap();
        match &b.segments[0] {
            MessageSegment::Text(t) => assert_eq!(t, "from server B"),
            _ => panic!("expected text"),
        }
    }

    #[test]
    fn test_cache_key_different_agent_directory_version() {
        let mut cache = MessageCache::new();
        let key_v1 = CacheKey {
            message_id: "m1".into(),
            revision_token: "r1".into(),
            server_id: "srv".into(),
            agent_directory_version: 1,
        };
        let key_v2 = CacheKey {
            message_id: "m1".into(),
            revision_token: "r1".into(),
            server_id: "srv".into(),
            agent_directory_version: 2,
        };

        cache.insert(key_v1.clone(), make_cached("v1"));
        cache.insert(key_v2.clone(), make_cached("v2"));

        assert_eq!(cache.len(), 2);
        assert!(cache.get(&key_v1).is_some());
        assert!(cache.get(&key_v2).is_some());
    }

    #[test]
    fn test_cache_overwrite_same_key() {
        let mut cache = MessageCache::new();
        let key = make_key("m1", "r1");

        cache.insert(key.clone(), make_cached("first"));
        cache.insert(key.clone(), make_cached("second"));

        assert_eq!(cache.len(), 1);
        let got = cache.get(&key).unwrap();
        match &got.segments[0] {
            MessageSegment::Text(t) => assert_eq!(t, "second"),
            _ => panic!("expected text"),
        }
    }

    // -- Integration: cache + extract --

    #[test]
    fn test_cache_with_extracted_segments() {
        let mut cache = MessageCache::new();
        let text = "Hello\n```rust\nfn main() {}\n```\nGoodbye";
        let segments = extract_message_segments(text);
        let key = make_key("m1", "r1");

        cache.insert(
            key.clone(),
            CachedMessage {
                segments,
                tool_calls: vec![],
            },
        );

        let cached = cache.get(&key).unwrap();
        assert_eq!(cached.segments.len(), 3);
    }
}
