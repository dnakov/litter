use crate::hydration::FfiMessageSegment;
use crate::parser::FfiToolCallCard;

#[derive(uniffi::Object)]
pub struct MessageParser;

#[uniffi::export]
impl MessageParser {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self
    }

    pub fn parse_tool_calls_typed(&self, text: String) -> Vec<FfiToolCallCard> {
        crate::parser::parse_tool_call_message(&text)
            .iter()
            .map(FfiToolCallCard::from)
            .collect()
    }

    pub fn extract_segments_typed(&self, text: String) -> Vec<FfiMessageSegment> {
        crate::hydration::extract_message_segments(&text)
            .into_iter()
            .map(FfiMessageSegment::from)
            .collect()
    }
}
