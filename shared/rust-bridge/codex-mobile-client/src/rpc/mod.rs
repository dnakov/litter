use std::sync::atomic::{AtomicI64, Ordering};

static REQUEST_COUNTER: AtomicI64 = AtomicI64::new(1);

pub(crate) fn next_request_id() -> i64 {
    REQUEST_COUNTER.fetch_add(1, Ordering::Relaxed)
}

#[derive(Debug, thiserror::Error)]
pub enum RpcClientError {
    #[error("RPC: {0}")]
    Rpc(String),
    #[error("Serialization: {0}")]
    Serialization(String),
}

#[path = "client_impl.rs"]
pub mod client_impl;

impl From<codex_utils_absolute_path::AbsolutePathBuf> for crate::types::AbsolutePath {
    fn from(value: codex_utils_absolute_path::AbsolutePathBuf) -> Self {
        Self {
            value: value.to_string_lossy().into_owned(),
        }
    }
}

impl From<std::path::PathBuf> for crate::types::AbsolutePath {
    fn from(value: std::path::PathBuf) -> Self {
        Self {
            value: value.to_string_lossy().into_owned(),
        }
    }
}

impl TryFrom<crate::types::AbsolutePath> for codex_utils_absolute_path::AbsolutePathBuf {
    type Error = RpcClientError;

    fn try_from(value: crate::types::AbsolutePath) -> Result<Self, Self::Error> {
        codex_utils_absolute_path::AbsolutePathBuf::try_from(value.value).map_err(|e| {
            RpcClientError::Serialization(format!("convert AbsolutePath -> AbsolutePathBuf: {e}"))
        })
    }
}

impl From<serde_json::Value> for crate::types::JsonValue {
    fn from(value: serde_json::Value) -> Self {
        match value {
            serde_json::Value::Null => Self {
                kind: crate::types::JsonValueKind::Null,
                bool_value: None,
                i64_value: None,
                u64_value: None,
                f64_value: None,
                string_value: None,
                array_items: None,
                object_entries: None,
            },
            serde_json::Value::Bool(value) => Self {
                kind: crate::types::JsonValueKind::Bool,
                bool_value: Some(value),
                i64_value: None,
                u64_value: None,
                f64_value: None,
                string_value: None,
                array_items: None,
                object_entries: None,
            },
            serde_json::Value::Number(number) => {
                let (kind, i64_value, u64_value, f64_value) = if let Some(value) = number.as_i64() {
                    (crate::types::JsonValueKind::I64, Some(value), None, None)
                } else if let Some(value) = number.as_u64() {
                    (crate::types::JsonValueKind::U64, None, Some(value), None)
                } else {
                    (
                        crate::types::JsonValueKind::F64,
                        None,
                        None,
                        Some(number.as_f64().unwrap_or_default()),
                    )
                };
                Self {
                    kind,
                    bool_value: None,
                    i64_value,
                    u64_value,
                    f64_value,
                    string_value: None,
                    array_items: None,
                    object_entries: None,
                }
            }
            serde_json::Value::String(value) => Self {
                kind: crate::types::JsonValueKind::String,
                bool_value: None,
                i64_value: None,
                u64_value: None,
                f64_value: None,
                string_value: Some(value),
                array_items: None,
                object_entries: None,
            },
            serde_json::Value::Array(values) => Self {
                kind: crate::types::JsonValueKind::Array,
                bool_value: None,
                i64_value: None,
                u64_value: None,
                f64_value: None,
                string_value: None,
                array_items: Some(values.into_iter().map(Into::into).collect()),
                object_entries: None,
            },
            serde_json::Value::Object(values) => Self {
                kind: crate::types::JsonValueKind::Object,
                bool_value: None,
                i64_value: None,
                u64_value: None,
                f64_value: None,
                string_value: None,
                array_items: None,
                object_entries: Some(
                    values
                        .into_iter()
                        .map(|(key, value)| crate::types::JsonObjectEntry {
                            key,
                            value: value.into(),
                        })
                        .collect(),
                ),
            },
        }
    }
}

impl TryFrom<crate::types::JsonValue> for serde_json::Value {
    type Error = RpcClientError;

    fn try_from(value: crate::types::JsonValue) -> Result<Self, Self::Error> {
        Ok(match value.kind {
            crate::types::JsonValueKind::Null => serde_json::Value::Null,
            crate::types::JsonValueKind::Bool => {
                serde_json::Value::Bool(value.bool_value.unwrap_or(false))
            }
            crate::types::JsonValueKind::I64 => {
                serde_json::Value::Number(value.i64_value.unwrap_or_default().into())
            }
            crate::types::JsonValueKind::U64 => {
                serde_json::Value::Number(value.u64_value.unwrap_or_default().into())
            }
            crate::types::JsonValueKind::F64 => {
                serde_json::Number::from_f64(value.f64_value.unwrap_or_default())
                    .map(serde_json::Value::Number)
                    .unwrap_or(serde_json::Value::Null)
            }
            crate::types::JsonValueKind::String => {
                serde_json::Value::String(value.string_value.unwrap_or_default())
            }
            crate::types::JsonValueKind::Array => serde_json::Value::Array(
                value
                    .array_items
                    .unwrap_or_default()
                    .into_iter()
                    .map(TryInto::try_into)
                    .collect::<Result<Vec<_>, _>>()?,
            ),
            crate::types::JsonValueKind::Object => serde_json::Value::Object(
                value
                    .object_entries
                    .unwrap_or_default()
                    .into_iter()
                    .map(|entry| Ok((entry.key, entry.value.try_into()?)))
                    .collect::<Result<serde_json::Map<String, serde_json::Value>, RpcClientError>>(
                    )?,
            ),
        })
    }
}

impl TryFrom<crate::types::AppDynamicToolSpec> for codex_protocol::dynamic_tools::DynamicToolSpec {
    type Error = RpcClientError;

    fn try_from(value: crate::types::AppDynamicToolSpec) -> Result<Self, Self::Error> {
        Ok(Self {
            name: value.name,
            description: value.description,
            input_schema: value.input_schema.try_into()?,
            defer_loading: value.defer_loading,
        })
    }
}

impl From<codex_protocol::dynamic_tools::DynamicToolSpec> for crate::types::AppDynamicToolSpec {
    fn from(value: codex_protocol::dynamic_tools::DynamicToolSpec) -> Self {
        Self {
            name: value.name,
            description: value.description,
            input_schema: value.input_schema.into(),
            defer_loading: value.defer_loading,
        }
    }
}

impl TryFrom<crate::types::ModelAvailabilityNux>
    for codex_protocol::openai_models::ModelAvailabilityNux
{
    type Error = RpcClientError;

    fn try_from(value: crate::types::ModelAvailabilityNux) -> Result<Self, Self::Error> {
        Ok(Self {
            message: value.message,
        })
    }
}

impl From<codex_protocol::openai_models::ModelAvailabilityNux>
    for crate::types::ModelAvailabilityNux
{
    fn from(value: codex_protocol::openai_models::ModelAvailabilityNux) -> Self {
        Self {
            message: value.message,
        }
    }
}
