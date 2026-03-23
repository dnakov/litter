use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::types::generated::{JsonObjectEntry, JsonValue, JsonValueKind};
use crate::types::ThreadKey;
use crate::uniffi_shared::{
    AppVoiceHandoffRequest, AppVoiceSpeaker, AppVoiceTranscriptUpdate,
};

#[derive(Debug, Clone)]
pub enum VoiceDerivedUpdate {
    Transcript(AppVoiceTranscriptUpdate),
    HandoffRequest(AppVoiceHandoffRequest),
    SpeechStarted,
}

#[derive(Default)]
pub struct VoiceRealtimeState {
    threads: Mutex<HashMap<ThreadKey, VoiceRealtimeThreadState>>,
}

#[derive(Default)]
struct VoiceRealtimeThreadState {
    next_virtual_id: u64,
    pending_user_item_id: Option<String>,
    pending_assistant_item_id: Option<String>,
    live_user_text: String,
    live_assistant_text: String,
    last_delta: Option<LastDelta>,
}

struct LastDelta {
    speaker: AppVoiceSpeaker,
    delta: String,
    timestamp: Instant,
}

impl VoiceRealtimeState {
    pub fn reset_thread(&self, key: &ThreadKey) {
        self.threads
            .lock()
            .expect("voice state lock poisoned")
            .insert(key.clone(), VoiceRealtimeThreadState::default());
    }

    pub fn clear_thread(&self, key: &ThreadKey) {
        self.threads
            .lock()
            .expect("voice state lock poisoned")
            .remove(key);
    }

    pub fn handle_item(&self, key: &ThreadKey, item: &JsonValue) -> Vec<VoiceDerivedUpdate> {
        let mut threads = self.threads.lock().expect("voice state lock poisoned");
        let thread = threads.entry(key.clone()).or_default();
        thread.handle_item(item)
    }
}

impl VoiceRealtimeThreadState {
    fn handle_item(&mut self, item: &JsonValue) -> Vec<VoiceDerivedUpdate> {
        let item_type = json_string_for_keys(item, &["type"]).unwrap_or_default();
        match item_type.as_str() {
            "handoff_request" => vec![VoiceDerivedUpdate::HandoffRequest(AppVoiceHandoffRequest {
                handoff_id: json_string_for_keys(item, &["handoff_id", "handoffId", "id"])
                    .unwrap_or_else(|| self.next_virtual_item_id("handoff")),
                input_transcript: json_string_for_keys(item, &["input_transcript", "inputTranscript"])
                    .unwrap_or_default(),
                active_transcript: parse_active_transcript(item),
                server_hint: json_string_for_keys(item, &["server_hint", "serverHint", "server"]),
                fallback_transcript: json_string_for_keys(
                    item,
                    &["fallback_transcript", "fallbackTranscript"],
                ),
            })],
            "message" => self.handle_message_item(item),
            "input_transcript_delta" => self.handle_transcript_delta(item, AppVoiceSpeaker::User),
            "output_transcript_delta" => {
                self.handle_transcript_delta(item, AppVoiceSpeaker::Assistant)
            }
            "speech_started" => {
                self.pending_user_item_id = None;
                self.live_user_text.clear();
                vec![VoiceDerivedUpdate::SpeechStarted]
            }
            _ => Vec::new(),
        }
    }

    fn handle_message_item(&mut self, item: &JsonValue) -> Vec<VoiceDerivedUpdate> {
        let role = json_string_for_keys(item, &["role"]).unwrap_or_else(|| "assistant".to_string());
        let speaker = if role == "user" {
            AppVoiceSpeaker::User
        } else {
            AppVoiceSpeaker::Assistant
        };
        let upstream_item_id = json_string_for_keys(item, &["id"]);
        let text = parse_message_text(item);
        let display_item_id = self.resolve_display_item_id(speaker, upstream_item_id.as_deref());

        if text.trim().is_empty() {
            self.set_pending_item_id(speaker, Some(display_item_id));
            return Vec::new();
        }

        let merged = merge_text(self.live_text(speaker), &text);
        self.set_live_text(speaker, String::new());
        self.set_pending_item_id(speaker, None);

        vec![VoiceDerivedUpdate::Transcript(AppVoiceTranscriptUpdate {
            item_id: display_item_id,
            speaker,
            text: merged,
            is_final: true,
        })]
    }

    fn handle_transcript_delta(
        &mut self,
        item: &JsonValue,
        speaker: AppVoiceSpeaker,
    ) -> Vec<VoiceDerivedUpdate> {
        let delta = json_string_for_keys(item, &["delta"]).unwrap_or_default();
        if delta.is_empty() || self.should_skip_delta(&delta, speaker) {
            return Vec::new();
        }

        let display_item_id = self.resolve_display_item_id(speaker, None);
        let merged = merge_text(self.live_text(speaker), &delta);
        self.set_live_text(speaker, merged.clone());
        self.set_pending_item_id(speaker, Some(display_item_id.clone()));

        vec![VoiceDerivedUpdate::Transcript(AppVoiceTranscriptUpdate {
            item_id: display_item_id,
            speaker,
            text: merged,
            is_final: false,
        })]
    }

    fn should_skip_delta(&mut self, delta: &str, speaker: AppVoiceSpeaker) -> bool {
        let now = Instant::now();
        if let Some(previous) = &self.last_delta {
            if previous.speaker == speaker
                && previous.delta == delta
                && now.duration_since(previous.timestamp) < Duration::from_millis(500)
            {
                return true;
            }
        }
        self.last_delta = Some(LastDelta {
            speaker,
            delta: delta.to_string(),
            timestamp: now,
        });
        false
    }

    fn resolve_display_item_id(
        &mut self,
        speaker: AppVoiceSpeaker,
        upstream_item_id: Option<&str>,
    ) -> String {
        self.pending_item_id(speaker)
            .or_else(|| {
                upstream_item_id.and_then(|value| {
                    let trimmed = value.trim();
                    (!trimmed.is_empty()).then_some(trimmed.to_string())
                })
            })
            .unwrap_or_else(|| self.next_virtual_item_id(match speaker {
                AppVoiceSpeaker::User => "user",
                AppVoiceSpeaker::Assistant => "assistant",
            }))
    }

    fn pending_item_id(&self, speaker: AppVoiceSpeaker) -> Option<String> {
        match speaker {
            AppVoiceSpeaker::User => self.pending_user_item_id.clone(),
            AppVoiceSpeaker::Assistant => self.pending_assistant_item_id.clone(),
        }
    }

    fn set_pending_item_id(&mut self, speaker: AppVoiceSpeaker, item_id: Option<String>) {
        match speaker {
            AppVoiceSpeaker::User => self.pending_user_item_id = item_id,
            AppVoiceSpeaker::Assistant => self.pending_assistant_item_id = item_id,
        }
    }

    fn live_text(&self, speaker: AppVoiceSpeaker) -> &str {
        match speaker {
            AppVoiceSpeaker::User => self.live_user_text.as_str(),
            AppVoiceSpeaker::Assistant => self.live_assistant_text.as_str(),
        }
    }

    fn set_live_text(&mut self, speaker: AppVoiceSpeaker, text: String) {
        match speaker {
            AppVoiceSpeaker::User => self.live_user_text = text,
            AppVoiceSpeaker::Assistant => self.live_assistant_text = text,
        }
    }

    fn next_virtual_item_id(&mut self, prefix: &str) -> String {
        let value = format!("voice-{prefix}-{}", self.next_virtual_id);
        self.next_virtual_id += 1;
        value
    }
}

fn merge_text(existing: &str, incoming: &str) -> String {
    if existing.is_empty() {
        return incoming.to_string();
    }
    if existing == incoming || existing.ends_with(incoming) {
        return existing.to_string();
    }
    if incoming.starts_with(existing) {
        return incoming.to_string();
    }
    if existing.starts_with(incoming) {
        return existing.to_string();
    }
    format!("{existing}{incoming}")
}

fn parse_message_text(item: &JsonValue) -> String {
    json_array_for_key(item, "content")
        .into_iter()
        .flatten()
        .filter_map(|part| {
            (json_string_for_keys(part, &["type"]).as_deref() == Some("text"))
                .then(|| json_string_for_keys(part, &["text"]))
                .flatten()
        })
        .collect::<Vec<_>>()
        .join(" ")
        .trim()
        .to_string()
}

fn parse_active_transcript(item: &JsonValue) -> String {
    let from_array = json_array_for_keys(item, &["active_transcript", "activeTranscript"])
        .into_iter()
        .flatten()
        .filter_map(|entry| {
            let role = json_string_for_keys(entry, &["role"])?;
            let text = json_string_for_keys(entry, &["text"])?;
            Some(format!("{role}: {text}"))
        })
        .collect::<Vec<_>>()
        .join("\n");

    if from_array.is_empty() {
        json_string_for_keys(item, &["active_transcript", "activeTranscript"]).unwrap_or_default()
    } else {
        from_array
    }
}

fn json_string_for_keys(value: &JsonValue, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| json_value_for_key(value, key))
        .and_then(json_string)
}

fn json_array_for_keys<'a>(value: &'a JsonValue, keys: &[&str]) -> Option<&'a [JsonValue]> {
    keys.iter()
        .find_map(|key| json_value_for_key(value, key))
        .and_then(json_array)
}

fn json_array_for_key<'a>(value: &'a JsonValue, key: &str) -> Option<&'a [JsonValue]> {
    json_value_for_key(value, key).and_then(json_array)
}

fn json_value_for_key<'a>(value: &'a JsonValue, key: &str) -> Option<&'a JsonValue> {
    if value.kind != JsonValueKind::Object {
        return None;
    }
    value
        .object_entries
        .as_ref()?
        .iter()
        .find(|entry: &&JsonObjectEntry| entry.key == key)
        .map(|entry| &entry.value)
}

fn json_string(value: &JsonValue) -> Option<String> {
    match value.kind {
        JsonValueKind::String => value.string_value.clone(),
        JsonValueKind::I64 => value.i64_value.map(|value| value.to_string()),
        JsonValueKind::U64 => value.u64_value.map(|value| value.to_string()),
        JsonValueKind::F64 => value.f64_value.map(|value| value.to_string()),
        JsonValueKind::Bool => value.bool_value.map(|value| value.to_string()),
        _ => None,
    }
}

fn json_array(value: &JsonValue) -> Option<&[JsonValue]> {
    if value.kind == JsonValueKind::Array {
        value.array_items.as_deref()
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::{VoiceDerivedUpdate, VoiceRealtimeState};
    use crate::types::ThreadKey;
    use crate::types::generated::JsonValue;
    use serde_json::json;

    fn json_value(value: serde_json::Value) -> JsonValue {
        serde_json::from_value(value).expect("json value should convert")
    }

    #[test]
    fn transcript_deltas_are_merged_and_deduped() {
        let state = VoiceRealtimeState::default();
        let key = ThreadKey {
            server_id: "local".into(),
            thread_id: "voice-thread".into(),
        };

        let updates = state.handle_item(
            &key,
            &json_value(json!({"type": "input_transcript_delta", "delta": "Hel"})),
        );
        let [VoiceDerivedUpdate::Transcript(first)] = updates.as_slice() else {
            panic!("expected transcript update");
        };
        assert_eq!(first.text, "Hel");
        assert!(!first.is_final);

        let updates = state.handle_item(
            &key,
            &json_value(json!({"type": "input_transcript_delta", "delta": "Hello"})),
        );
        let [VoiceDerivedUpdate::Transcript(second)] = updates.as_slice() else {
            panic!("expected merged transcript update");
        };
        assert_eq!(second.text, "Hello");

        let updates = state.handle_item(
            &key,
            &json_value(json!({"type": "input_transcript_delta", "delta": "Hello"})),
        );
        assert!(updates.is_empty());
    }

    #[test]
    fn final_message_reuses_pending_transcript_row() {
        let state = VoiceRealtimeState::default();
        let key = ThreadKey {
            server_id: "local".into(),
            thread_id: "voice-thread".into(),
        };

        let updates = state.handle_item(
            &key,
            &json_value(json!({"type": "output_transcript_delta", "delta": "Tool"})),
        );
        let [VoiceDerivedUpdate::Transcript(first)] = updates.as_slice() else {
            panic!("expected transcript update");
        };

        let updates = state.handle_item(
            &key,
            &json_value(json!({
                "type": "message",
                "role": "assistant",
                "id": "item_123",
                "content": [{"type": "text", "text": "Tool result"}]
            })),
        );
        let [VoiceDerivedUpdate::Transcript(second)] = updates.as_slice() else {
            panic!("expected final message update");
        };
        assert_eq!(first.item_id, second.item_id);
        assert_eq!(second.text, "Tool result");
        assert!(second.is_final);
    }

    #[test]
    fn handoff_request_is_normalized() {
        let state = VoiceRealtimeState::default();
        let key = ThreadKey {
            server_id: "local".into(),
            thread_id: "voice-thread".into(),
        };
        let updates = state.handle_item(
            &key,
            &json_value(json!({
                "type": "handoff_request",
                "handoff_id": "handoff-1",
                "input_transcript": "Search docs",
                "active_transcript": [{"role": "user", "text": "Search docs"}],
                "server_hint": "remote"
            })),
        );
        let [VoiceDerivedUpdate::HandoffRequest(request)] = updates.as_slice() else {
            panic!("expected handoff request");
        };
        assert_eq!(request.handoff_id, "handoff-1");
        assert_eq!(request.input_transcript, "Search docs");
        assert_eq!(request.active_transcript, "user: Search docs");
        assert_eq!(request.server_hint.as_deref(), Some("remote"));
    }
}
