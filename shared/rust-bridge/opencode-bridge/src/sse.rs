use crate::OpenCodeBridgeError;

#[derive(Debug, Default)]
pub(crate) struct SseParser {
    pending_line: Vec<u8>,
    data_lines: Vec<String>,
}

impl SseParser {
    pub(crate) fn push(
        &mut self,
        chunk: &[u8],
        endpoint: &'static str,
    ) -> Result<Vec<String>, OpenCodeBridgeError> {
        let mut payloads = Vec::new();

        for &byte in chunk {
            if byte == b'\n' {
                self.finish_line(endpoint, &mut payloads)?;
            } else {
                self.pending_line.push(byte);
            }
        }

        Ok(payloads)
    }

    pub(crate) fn finish(
        &mut self,
        endpoint: &'static str,
    ) -> Result<Vec<String>, OpenCodeBridgeError> {
        let mut payloads = Vec::new();

        if !self.pending_line.is_empty() {
            self.finish_line(endpoint, &mut payloads)?;
        }

        if let Some(payload) = self.finish_record() {
            payloads.push(payload);
        }

        Ok(payloads)
    }

    fn finish_line(
        &mut self,
        endpoint: &'static str,
        payloads: &mut Vec<String>,
    ) -> Result<(), OpenCodeBridgeError> {
        let line = if self.pending_line.last() == Some(&b'\r') {
            &self.pending_line[..self.pending_line.len().saturating_sub(1)]
        } else {
            self.pending_line.as_slice()
        };

        let line = std::str::from_utf8(line).map_err(|source| {
            OpenCodeBridgeError::sse_protocol(
                endpoint,
                format!("stream line is not valid utf-8: {source}"),
                Some(String::from_utf8_lossy(&self.pending_line).into_owned()),
            )
        })?;

        if line.is_empty() {
            if let Some(payload) = self.finish_record() {
                payloads.push(payload);
            }
            self.pending_line.clear();
            return Ok(());
        }

        if let Some(rest) = line.strip_prefix(':') {
            let _ = rest;
            self.pending_line.clear();
            return Ok(());
        }

        let (field, value) = match line.split_once(':') {
            Some((field, value)) => (field, value.strip_prefix(' ').unwrap_or(value)),
            None => (line, ""),
        };

        if field == "data" {
            self.data_lines.push(value.to_string());
        }

        self.pending_line.clear();
        Ok(())
    }

    fn finish_record(&mut self) -> Option<String> {
        if self.data_lines.is_empty() {
            return None;
        }

        let payload = self.data_lines.join("\n");
        self.data_lines.clear();
        Some(payload)
    }
}
