use codex_ipc::{ImmerOp, ImmerPatch, ImmerPathSegment};
use serde_json::Value;

#[derive(Debug)]
pub enum PatchError {
    PathNotFound { segment: String },
    IndexOutOfBounds { index: usize, len: usize },
    UnexpectedType { kind: &'static str },
    MissingValue,
}

impl std::fmt::Display for PatchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::PathNotFound { segment } => write!(f, "path segment {segment:?} not found"),
            Self::IndexOutOfBounds { index, len } => {
                write!(f, "array index {index} out of bounds (len={len})")
            }
            Self::UnexpectedType { kind } => write!(f, "expected object or array, got {kind}"),
            Self::MissingValue => write!(f, "add/replace operation missing value"),
        }
    }
}

impl std::error::Error for PatchError {}

/// Apply a sequence of Immer patches to a JSON value, mutating it in place.
pub fn apply_patches(target: &mut Value, patches: &[ImmerPatch]) -> Result<(), PatchError> {
    for patch in patches {
        apply_one(target, patch)?;
    }
    Ok(())
}

fn apply_one(target: &mut Value, patch: &ImmerPatch) -> Result<(), PatchError> {
    if patch.path.is_empty() {
        // Empty path = replace root
        match patch.op {
            ImmerOp::Replace | ImmerOp::Add => {
                *target = patch.value.clone().ok_or(PatchError::MissingValue)?;
            }
            ImmerOp::Remove => {
                *target = Value::Null;
            }
        }
        return Ok(());
    }

    // Navigate to the parent of the target location
    let (parent_path, last_segment) = patch.path.split_at(patch.path.len() - 1);
    let parent = navigate_to(target, parent_path)?;
    let last = &last_segment[0];

    match patch.op {
        ImmerOp::Replace => {
            let val = patch.value.clone().ok_or(PatchError::MissingValue)?;
            set_at(parent, last, val)
        }
        ImmerOp::Add => {
            let val = patch.value.clone().ok_or(PatchError::MissingValue)?;
            add_at(parent, last, val)
        }
        ImmerOp::Remove => remove_at(parent, last),
    }
}

fn navigate_to<'a>(
    root: &'a mut Value,
    path: &[ImmerPathSegment],
) -> Result<&'a mut Value, PatchError> {
    let mut current = root;
    for segment in path {
        let kind = value_kind(current);
        current = match segment {
            ImmerPathSegment::Key(key) => {
                let obj = current
                    .as_object_mut()
                    .ok_or(PatchError::UnexpectedType { kind })?;
                obj.get_mut(key).ok_or_else(|| PatchError::PathNotFound {
                    segment: key.clone(),
                })?
            }
            ImmerPathSegment::Index(idx) => {
                let arr = current
                    .as_array_mut()
                    .ok_or(PatchError::UnexpectedType { kind })?;
                let len = arr.len();
                arr.get_mut(*idx)
                    .ok_or(PatchError::IndexOutOfBounds { index: *idx, len })?
            }
        };
    }
    Ok(current)
}

fn set_at(parent: &mut Value, segment: &ImmerPathSegment, val: Value) -> Result<(), PatchError> {
    let kind = value_kind(parent);
    match segment {
        ImmerPathSegment::Key(key) => {
            let obj = parent
                .as_object_mut()
                .ok_or(PatchError::UnexpectedType { kind })?;
            obj.insert(key.clone(), val);
            Ok(())
        }
        ImmerPathSegment::Index(idx) => {
            let arr = parent
                .as_array_mut()
                .ok_or(PatchError::UnexpectedType { kind })?;
            let len = arr.len();
            if *idx >= len {
                return Err(PatchError::IndexOutOfBounds { index: *idx, len });
            }
            arr[*idx] = val;
            Ok(())
        }
    }
}

fn add_at(parent: &mut Value, segment: &ImmerPathSegment, val: Value) -> Result<(), PatchError> {
    let kind = value_kind(parent);
    match segment {
        ImmerPathSegment::Key(key) => {
            let obj = parent
                .as_object_mut()
                .ok_or(PatchError::UnexpectedType { kind })?;
            obj.insert(key.clone(), val);
            Ok(())
        }
        ImmerPathSegment::Index(idx) => {
            let arr = parent
                .as_array_mut()
                .ok_or(PatchError::UnexpectedType { kind })?;
            let len = arr.len();
            if *idx > len {
                return Err(PatchError::IndexOutOfBounds { index: *idx, len });
            }
            arr.insert(*idx, val);
            Ok(())
        }
    }
}

fn remove_at(parent: &mut Value, segment: &ImmerPathSegment) -> Result<(), PatchError> {
    let kind = value_kind(parent);
    match segment {
        ImmerPathSegment::Key(key) => {
            let obj = parent
                .as_object_mut()
                .ok_or(PatchError::UnexpectedType { kind })?;
            obj.remove(key).ok_or_else(|| PatchError::PathNotFound {
                segment: key.clone(),
            })?;
            Ok(())
        }
        ImmerPathSegment::Index(idx) => {
            let arr = parent
                .as_array_mut()
                .ok_or(PatchError::UnexpectedType { kind })?;
            let len = arr.len();
            if *idx >= len {
                return Err(PatchError::IndexOutOfBounds { index: *idx, len });
            }
            arr.remove(*idx);
            Ok(())
        }
    }
}

fn value_kind(v: &Value) -> &'static str {
    match v {
        Value::Null => "null",
        Value::Bool(_) => "bool",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn patch(op: ImmerOp, path: Vec<ImmerPathSegment>, value: Option<Value>) -> ImmerPatch {
        ImmerPatch { op, path, value }
    }

    fn key(s: &str) -> ImmerPathSegment {
        ImmerPathSegment::Key(s.to_string())
    }

    fn idx(i: usize) -> ImmerPathSegment {
        ImmerPathSegment::Index(i)
    }

    #[test]
    fn replace_at_key_path() {
        let mut v = json!({"a": {"b": 1}});
        apply_patches(
            &mut v,
            &[patch(
                ImmerOp::Replace,
                vec![key("a"), key("b")],
                Some(json!(2)),
            )],
        )
        .unwrap();
        assert_eq!(v, json!({"a": {"b": 2}}));
    }

    #[test]
    fn add_to_array() {
        let mut v = json!({"items": [1, 2, 3]});
        apply_patches(
            &mut v,
            &[patch(
                ImmerOp::Add,
                vec![key("items"), idx(1)],
                Some(json!(99)),
            )],
        )
        .unwrap();
        assert_eq!(v, json!({"items": [1, 99, 2, 3]}));
    }

    #[test]
    fn remove_from_array() {
        let mut v = json!({"items": [1, 2, 3]});
        apply_patches(
            &mut v,
            &[patch(ImmerOp::Remove, vec![key("items"), idx(1)], None)],
        )
        .unwrap();
        assert_eq!(v, json!({"items": [1, 3]}));
    }

    #[test]
    fn add_object_key() {
        let mut v = json!({"a": 1});
        apply_patches(
            &mut v,
            &[patch(ImmerOp::Add, vec![key("b")], Some(json!(2)))],
        )
        .unwrap();
        assert_eq!(v["b"], json!(2));
    }

    #[test]
    fn remove_object_key() {
        let mut v = json!({"a": 1, "b": 2});
        apply_patches(&mut v, &[patch(ImmerOp::Remove, vec![key("b")], None)]).unwrap();
        assert_eq!(v, json!({"a": 1}));
    }

    #[test]
    fn nested_path() {
        let mut v = json!({"turns": [{"items": [{"id": "a"}, {"id": "b"}, {"content": "old"}]}]});
        apply_patches(
            &mut v,
            &[patch(
                ImmerOp::Replace,
                vec![key("turns"), idx(0), key("items"), idx(2), key("content")],
                Some(json!("new")),
            )],
        )
        .unwrap();
        assert_eq!(v["turns"][0]["items"][2]["content"], json!("new"));
    }

    #[test]
    fn empty_path_replaces_root() {
        let mut v = json!({"old": true});
        apply_patches(
            &mut v,
            &[patch(ImmerOp::Replace, vec![], Some(json!({"new": true})))],
        )
        .unwrap();
        assert_eq!(v, json!({"new": true}));
    }

    #[test]
    fn multiple_patches() {
        let mut v = json!({"items": [1, 2, 3], "count": 3});
        apply_patches(
            &mut v,
            &[
                patch(ImmerOp::Add, vec![key("items"), idx(3)], Some(json!(4))),
                patch(ImmerOp::Replace, vec![key("count")], Some(json!(4))),
            ],
        )
        .unwrap();
        assert_eq!(v, json!({"items": [1, 2, 3, 4], "count": 4}));
    }

    #[test]
    fn error_index_out_of_bounds() {
        let mut v = json!({"items": [1, 2]});
        let result = apply_patches(
            &mut v,
            &[patch(
                ImmerOp::Replace,
                vec![key("items"), idx(5)],
                Some(json!(99)),
            )],
        );
        assert!(result.is_err());
    }

    #[test]
    fn error_missing_key() {
        let mut v = json!({"a": 1});
        let result = apply_patches(
            &mut v,
            &[patch(
                ImmerOp::Replace,
                vec![key("nonexistent"), key("child")],
                Some(json!(1)),
            )],
        );
        assert!(result.is_err());
    }

    #[test]
    fn error_type_mismatch() {
        let mut v = json!("a string");
        let result = apply_patches(
            &mut v,
            &[patch(ImmerOp::Replace, vec![key("key")], Some(json!(1)))],
        );
        assert!(result.is_err());
    }

    #[test]
    fn error_missing_value() {
        let mut v = json!({"a": 1});
        let result = apply_patches(&mut v, &[patch(ImmerOp::Replace, vec![key("a")], None)]);
        assert!(result.is_err());
    }
}
