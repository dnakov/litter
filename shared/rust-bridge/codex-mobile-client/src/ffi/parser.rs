use crate::hydration::AppMessageSegment;
use crate::parser::AppToolCallCard;

#[derive(uniffi::Object)]
pub struct MessageParser;

#[uniffi::export]
impl MessageParser {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self
    }

    pub fn parse_tool_calls_typed(&self, text: String) -> Vec<AppToolCallCard> {
        crate::parser::parse_tool_call_message(&text)
            .iter()
            .map(AppToolCallCard::from)
            .collect()
    }

    pub fn extract_segments_typed(&self, text: String) -> Vec<AppMessageSegment> {
        crate::hydration::extract_message_segments(&text)
            .into_iter()
            .map(AppMessageSegment::from)
            .collect()
    }
}
