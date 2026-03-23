//! codex-mobile-codegen
//!
//! Reads upstream `codex-app-server-protocol` Rust source files, extracts
//! public struct/enum definitions from the protocol module, and generates
//! UniFFI-annotated mobile wrapper types for codex-mobile-client.
//!
//! All types transitively referenced by Response/Notification types are
//! generated with proper nested references (not flattened to String).
//!
//! Usage:
//!   cargo run -p codex-mobile-codegen -- \
//!     --out ../codex-mobile-client/src/types/codegen_types.generated.rs \
//!     --rpc-out ../codex-mobile-client/src/rpc/generated_client.rs \
//!     --ffi-rpc-out ../codex-mobile-client/src/ffi/rpc.rs

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use syn::{self, Fields, Item, LitStr, Type, Visibility};

const PARAM_ROOT_TYPES: &[&str] = &[
    "DynamicToolSpec",
    "ThreadStartParams",
    "ThreadListParams",
    "ThreadReadParams",
    "ThreadResumeParams",
    "ThreadForkParams",
    "ThreadArchiveParams",
    "ThreadRollbackParams",
    "TurnStartParams",
    "TurnInterruptParams",
    "ThreadSetNameParams",
    "ModelListParams",
    "SkillsListParams",
    "ExperimentalFeatureListParams",
    "ConfigReadParams",
    "ConfigValueWriteParams",
    "ConfigBatchWriteParams",
    "ReviewStartParams",
    "GetAccountParams",
    "LoginAccountParams",
    "CancelLoginAccountParams",
    "ThreadRealtimeStartParams",
    "ThreadRealtimeAppendAudioParams",
    "ThreadRealtimeAppendTextParams",
    "ThreadRealtimeStopParams",
    "ThreadRealtimeResolveHandoffParams",
    "ThreadRealtimeFinalizeHandoffParams",
    "CommandExecParams",
    "FuzzyFileSearchParams",
    "GetAuthStatusParams",
];

const SUPPORTED_RPC_VARIANTS: &[&str] = &[
    "ThreadStart",
    "ThreadList",
    "ThreadRead",
    "ThreadResume",
    "ThreadFork",
    "ThreadArchive",
    "ThreadRollback",
    "ThreadSetName",
    "TurnStart",
    "TurnInterrupt",
    "SkillsList",
    "ThreadRealtimeStart",
    "ThreadRealtimeAppendAudio",
    "ThreadRealtimeAppendText",
    "ThreadRealtimeStop",
    "ThreadRealtimeResolveHandoff",
    "ThreadRealtimeFinalizeHandoff",
    "ReviewStart",
    "ModelList",
    "ExperimentalFeatureList",
    "LoginAccount",
    "LogoutAccount",
    "GetAccountRateLimits",
    "ConfigValueWrite",
    "GetAccount",
    "FuzzyFileSearch",
    "GetAuthStatus",
    "OneOffCommandExec",
];

const EXCLUDED_GENERATED_TYPES: &[&str] = &[];

const DIRECT_CONVERSION_SKIP_TYPES: &[&str] = &["TextElement"];

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let workspace_dir = manifest_dir
        .parent()
        .expect("codegen crate should live under shared/rust-bridge");

    let upstream_path = args
        .iter()
        .position(|a| a == "--upstream")
        .map(|i| PathBuf::from(&args[i + 1]))
        .unwrap_or_else(|| {
            workspace_dir
                .join("../third_party/codex/codex-rs/app-server-protocol/src/protocol/v2.rs")
        });

    let out_path = args
        .iter()
        .position(|a| a == "--out")
        .map(|i| PathBuf::from(&args[i + 1]));

    let rpc_out_path = args
        .iter()
        .position(|a| a == "--rpc-out")
        .map(|i| PathBuf::from(&args[i + 1]));

    let ffi_rpc_out_path = args
        .iter()
        .position(|a| a == "--ffi-rpc-out")
        .map(|i| PathBuf::from(&args[i + 1]));

    let common_path = args
        .iter()
        .position(|a| a == "--common")
        .map(|i| PathBuf::from(&args[i + 1]))
        .unwrap_or_else(|| {
            workspace_dir
                .join("../third_party/codex/codex-rs/app-server-protocol/src/protocol/common.rs")
        });

    let protocol_config_types_path = workspace_dir
        .join("../third_party/codex/codex-rs/protocol/src/config_types.rs");
    let protocol_openai_models_path = workspace_dir
        .join("../third_party/codex/codex-rs/protocol/src/openai_models.rs");
    let protocol_account_path =
        workspace_dir.join("../third_party/codex/codex-rs/protocol/src/account.rs");
    let protocol_models_path =
        workspace_dir.join("../third_party/codex/codex-rs/protocol/src/models.rs");
    let protocol_parse_command_path = workspace_dir
        .join("../third_party/codex/codex-rs/protocol/src/parse_command.rs");
    let protocol_path = workspace_dir.join("../third_party/codex/codex-rs/protocol/src/protocol.rs");

    let v1_path = args
        .iter()
        .position(|a| a == "--v1")
        .map(|i| PathBuf::from(&args[i + 1]))
        .unwrap_or_else(|| {
            workspace_dir
                .join("../third_party/codex/codex-rs/app-server-protocol/src/protocol/v1.rs")
        });

    eprintln!("Reading upstream types from: {}", upstream_path.display());

    let mut structs: BTreeMap<String, StructDef> = BTreeMap::new();
    let mut enums: BTreeMap<String, EnumDef> = BTreeMap::new();
    collect_public_items(&upstream_path, &mut structs, &mut enums);
    collect_public_items(&common_path, &mut structs, &mut enums);
    collect_public_items(&v1_path, &mut structs, &mut enums);
    collect_public_items(&protocol_config_types_path, &mut structs, &mut enums);
    collect_public_items(&protocol_openai_models_path, &mut structs, &mut enums);
    collect_public_items(&protocol_account_path, &mut structs, &mut enums);
    collect_public_items(&protocol_models_path, &mut structs, &mut enums);
    collect_public_items(&protocol_parse_command_path, &mut structs, &mut enums);
    collect_selected_public_items(
        &protocol_path,
        &["SubAgentSource"],
        &mut structs,
        &mut enums,
    );

    eprintln!("Found {} structs, {} enums", structs.len(), enums.len());

    // Build the set of all known type names for reference resolution.
    let all_known: BTreeSet<String> = structs.keys().chain(enums.keys()).cloned().collect();

    // Types that are hand-maintained in other modules (enums.rs, models.rs, etc.)
    // and must NOT be re-generated to avoid UniFFI symbol collisions.
    let excluded: BTreeSet<String> = EXCLUDED_GENERATED_TYPES
        .iter()
        .map(|s| s.to_string())
        .collect();

    // Determine which types to generate via transitive closure from root types.
    let root_suffixes = ["Response", "Notification"];
    let mut needed: BTreeSet<String> = BTreeSet::new();

    // Seed with root types (Response + Notification).
    for name in all_known.iter() {
        if root_suffixes.iter().any(|s| name.ends_with(s)) {
            needed.insert(name.clone());
        }
    }

    // Keep the params/types that the mobile bridge exposes directly or relies on
    // for typed helper routing instead of generating every upstream params type.
    for name in PARAM_ROOT_TYPES {
        if all_known.contains(*name) {
            needed.insert((*name).to_string());
        }
    }

    needed = expand_type_closure(needed, &structs, &enums, &all_known);

    eprintln!("Types needed (transitive closure): {}", needed.len());

    // Remove excluded types from needed set.
    for ex in &excluded {
        needed.remove(ex);
    }

    let mut map_defs: Vec<MapFieldDef> = Vec::new();
    for (name, def) in &structs {
        if !needed.contains(name) {
            continue;
        }
        for field in &def.fields {
            if let Some(map_def) = map_field_def(name, &field.name, &field.ty, &all_known) {
                map_defs.push(map_def);
            }
        }
    }
    for (name, def) in &enums {
        if !needed.contains(name) {
            continue;
        }
        for variant in &def.variants {
            for field in &variant.fields {
                if let Some(map_def) = map_field_def(name, &field.name, &field.ty, &all_known) {
                    map_defs.push(map_def);
                }
            }
        }
    }
    map_defs.sort_by(|a, b| {
        a.entry_name
            .cmp(&b.entry_name)
            .then(a.deserialize_fn.cmp(&b.deserialize_fn))
            .then(a.serialize_fn.cmp(&b.serialize_fn))
    });
    map_defs.dedup_by(|a, b| {
        a.entry_name == b.entry_name
            && a.deserialize_fn == b.deserialize_fn
            && a.serialize_fn == b.serialize_fn
    });

    // Generate output.
    let mut output = String::new();
    output.push_str(
        "//! Auto-generated mobile wrapper types from upstream codex-app-server-protocol.\n",
    );
    output.push_str("//!\n");
    output.push_str("//! DO NOT EDIT — regenerate with: cargo run -p codex-mobile-codegen\n\n");
    output.push_str("use serde::{Deserialize, Serialize};\n\n");
    output.push_str(
        "#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]\n\
#[serde(transparent)]\n\
#[derive(uniffi::Record)]\n\
pub struct AbsolutePath {\n\
    pub value: String,\n\
}\n\n\
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]\n\
#[serde(untagged)]\n\
#[derive(uniffi::Enum)]\n\
pub enum RequestId {\n\
    String(String),\n\
    Integer(i64),\n\
}\n\n\
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]\n\
#[serde(rename_all = \"camelCase\")]\n\
#[derive(uniffi::Enum)]\n\
pub enum JsonValueKind {\n\
    Null,\n\
    Bool,\n\
    I64,\n\
    U64,\n\
    F64,\n\
    String,\n\
    Array,\n\
    Object,\n\
}\n\n\
#[derive(Debug, Clone, PartialEq)]\n\
#[derive(uniffi::Record)]\n\
pub struct JsonObjectEntry {\n\
    pub key: String,\n\
    pub value: JsonValue,\n\
}\n\n\
#[derive(Debug, Clone, PartialEq)]\n\
#[derive(uniffi::Record)]\n\
pub struct JsonValue {\n\
    pub kind: JsonValueKind,\n\
    pub bool_value: Option<bool>,\n\
    pub i64_value: Option<i64>,\n\
    pub u64_value: Option<u64>,\n\
    pub f64_value: Option<f64>,\n\
    pub string_value: Option<String>,\n\
    pub array_items: Option<Vec<JsonValue>>,\n\
    pub object_entries: Option<Vec<JsonObjectEntry>>,\n\
}\n\n\
impl Serialize for JsonValue {\n\
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>\n\
    where\n\
        S: serde::Serializer,\n\
    {\n\
        match self.kind {\n\
            JsonValueKind::Null => serializer.serialize_unit(),\n\
            JsonValueKind::Bool => serializer.serialize_bool(self.bool_value.unwrap_or(false)),\n\
            JsonValueKind::I64 => serializer.serialize_i64(self.i64_value.unwrap_or_default()),\n\
            JsonValueKind::U64 => serializer.serialize_u64(self.u64_value.unwrap_or_default()),\n\
            JsonValueKind::F64 => serializer.serialize_f64(self.f64_value.unwrap_or_default()),\n\
            JsonValueKind::String => serializer.serialize_str(self.string_value.as_deref().unwrap_or(\"\")),\n\
            JsonValueKind::Array => self.array_items.clone().unwrap_or_default().serialize(serializer),\n\
            JsonValueKind::Object => {\n\
                let map: std::collections::BTreeMap<String, JsonValue> = self\n\
                    .object_entries\n\
                    .clone()\n\
                    .unwrap_or_default()\n\
                    .into_iter()\n\
                    .map(|entry| (entry.key, entry.value))\n\
                    .collect();\n\
                map.serialize(serializer)\n\
            }\n\
        }\n\
    }\n\
}\n\n\
impl<'de> Deserialize<'de> for JsonValue {\n\
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>\n\
    where\n\
        D: serde::Deserializer<'de>,\n\
    {\n\
        let value = serde_json::Value::deserialize(deserializer)?;\n\
        Ok(match value {\n\
            serde_json::Value::Null => JsonValue {\n\
                kind: JsonValueKind::Null,\n\
                bool_value: None,\n\
                i64_value: None,\n\
                u64_value: None,\n\
                f64_value: None,\n\
                string_value: None,\n\
                array_items: None,\n\
                object_entries: None,\n\
            },\n\
            serde_json::Value::Bool(value) => JsonValue {\n\
                kind: JsonValueKind::Bool,\n\
                bool_value: Some(value),\n\
                i64_value: None,\n\
                u64_value: None,\n\
                f64_value: None,\n\
                string_value: None,\n\
                array_items: None,\n\
                object_entries: None,\n\
            },\n\
            serde_json::Value::Number(value) => {\n\
                if let Some(value) = value.as_i64() {\n\
                    JsonValue {\n\
                        kind: JsonValueKind::I64,\n\
                        bool_value: None,\n\
                        i64_value: Some(value),\n\
                        u64_value: None,\n\
                        f64_value: None,\n\
                        string_value: None,\n\
                        array_items: None,\n\
                        object_entries: None,\n\
                    }\n\
                } else if let Some(value) = value.as_u64() {\n\
                    JsonValue {\n\
                        kind: JsonValueKind::U64,\n\
                        bool_value: None,\n\
                        i64_value: None,\n\
                        u64_value: Some(value),\n\
                        f64_value: None,\n\
                        string_value: None,\n\
                        array_items: None,\n\
                        object_entries: None,\n\
                    }\n\
                } else {\n\
                    JsonValue {\n\
                        kind: JsonValueKind::F64,\n\
                        bool_value: None,\n\
                        i64_value: None,\n\
                        u64_value: None,\n\
                        f64_value: value.as_f64(),\n\
                        string_value: None,\n\
                        array_items: None,\n\
                        object_entries: None,\n\
                    }\n\
                }\n\
            }\n\
            serde_json::Value::String(value) => JsonValue {\n\
                kind: JsonValueKind::String,\n\
                bool_value: None,\n\
                i64_value: None,\n\
                u64_value: None,\n\
                f64_value: None,\n\
                string_value: Some(value),\n\
                array_items: None,\n\
                object_entries: None,\n\
            },\n\
            serde_json::Value::Array(values) => JsonValue {\n\
                kind: JsonValueKind::Array,\n\
                bool_value: None,\n\
                i64_value: None,\n\
                u64_value: None,\n\
                f64_value: None,\n\
                string_value: None,\n\
                array_items: Some(values.into_iter().map(serde_json::from_value).collect::<Result<Vec<JsonValue>, _>>().map_err(serde::de::Error::custom)?),\n\
                object_entries: None,\n\
            },\n\
            serde_json::Value::Object(values) => JsonValue {\n\
                kind: JsonValueKind::Object,\n\
                bool_value: None,\n\
                i64_value: None,\n\
                u64_value: None,\n\
                f64_value: None,\n\
                string_value: None,\n\
                array_items: None,\n\
                object_entries: Some(values.into_iter().map(|(key, value)| -> Result<JsonObjectEntry, D::Error> {\n\
                    Ok(JsonObjectEntry { key, value: serde_json::from_value(value).map_err(serde::de::Error::custom)? })\n\
                }).collect::<Result<Vec<JsonObjectEntry>, D::Error>>()?),\n\
            },\n\
        })\n\
    }\n\
}\n\n",
    );

    for map_def in &map_defs {
        output.push_str(&format!(
            "#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]\n\
#[derive(uniffi::Record)]\n\
pub struct {} {{\n\
    pub key: {},\n\
    pub value: {},\n\
}}\n\n\
fn {}<'de, D>(\n\
    deserializer: D,\n\
) -> Result<{}, D::Error>\n\
where\n\
    D: serde::Deserializer<'de>,\n\
{{\n",
            map_def.entry_name,
            map_type(&map_def.key_ty, &all_known),
            map_def.value_mapped_ty,
            map_def.deserialize_fn,
            if map_def.optional {
                format!("Option<Vec<{}>>", map_def.entry_name)
            } else {
                format!("Vec<{}>", map_def.entry_name)
            }
        ));
        if map_def.optional {
            output.push_str(&format!(
                "    let map = Option::<std::collections::BTreeMap<{}, {}>>::deserialize(deserializer)?;\n\
    Ok(map.map(|map| map.into_iter().map(|(key, value)| {} {{ key, value }}).collect()))\n",
                map_type(&map_def.key_ty, &all_known),
                map_def.value_mapped_ty,
                map_def.entry_name
            ));
        } else {
            output.push_str(&format!(
                "    let map = Option::<std::collections::BTreeMap<{}, {}>>::deserialize(deserializer)?\n\
        .unwrap_or_default();\n\
    Ok(map.into_iter().map(|(key, value)| {} {{ key, value }}).collect())\n",
                map_type(&map_def.key_ty, &all_known),
                map_def.value_mapped_ty,
                map_def.entry_name
            ));
        }
        output.push_str("}\n\n");
        output.push_str(&format!(
            "fn {}<S>(\n\
    entries: &{},\n\
    serializer: S,\n\
) -> Result<S::Ok, S::Error>\n\
where\n\
    S: serde::Serializer,\n\
{{\n",
            map_def.serialize_fn,
            if map_def.optional {
                format!("Option<Vec<{}>>", map_def.entry_name)
            } else {
                format!("Vec<{}>", map_def.entry_name)
            }
        ));
        if map_def.optional {
            output.push_str(&format!(
                "    match entries {{\n\
        Some(entries) => {{\n\
            let map: std::collections::BTreeMap<{}, {}> = entries.iter().map(|entry| (entry.key.clone(), entry.value.clone())).collect();\n\
            serializer.serialize_some(&map)\n\
        }}\n\
        None => serializer.serialize_none(),\n\
    }}\n",
                map_type(&map_def.key_ty, &all_known),
                map_def.value_mapped_ty
            ));
        } else {
            output.push_str(&format!(
                "    let map: std::collections::BTreeMap<{}, {}> = entries.iter().map(|entry| (entry.key.clone(), entry.value.clone())).collect();\n\
    map.serialize(serializer)\n",
                map_type(&map_def.key_ty, &all_known),
                map_def.value_mapped_ty
            ));
        }
        output.push_str("}\n\n");
    }

    let mut generated_count = 0;

    // Generate structs.
    for (name, def) in &structs {
        if !needed.contains(name) {
            continue;
        }
        output.push_str(&generate_wrapper_struct(def, &all_known));
        output.push('\n');
        generated_count += 1;
    }

    // Generate enums.
    for (name, def) in &enums {
        if !needed.contains(name) {
            continue;
        }
        output.push_str(&generate_wrapper_enum(def, &all_known));
        output.push('\n');
        generated_count += 1;
    }

    eprintln!("Generated {} wrapper types", generated_count);

    if let Some(out) = out_path {
        std::fs::write(&out, &output).expect("failed to write output");
        eprintln!("Written to: {}", out.display());
    } else {
        print!("{}", output);
    }

    // ── RPC method generation ────────────────────────────────────────
    if let Some(rpc_out) = rpc_out_path {
        let common_source =
            std::fs::read_to_string(&common_path).expect("failed to read common.rs");
        let rpc_methods = parse_client_requests(&common_source);
        eprintln!("Found {} ClientRequest variants", rpc_methods.len());

        let rpc_param_types = expand_type_closure(
            PARAM_ROOT_TYPES
                .iter()
                .filter(|name| all_known.contains(**name))
                .map(|name| (*name).to_string())
                .collect(),
            &structs,
            &enums,
            &all_known,
        );
        let rpc_output = generate_rpc_methods(
            &rpc_methods,
            &all_known,
            &rpc_param_types,
            &structs,
            &enums,
        );
        std::fs::write(&rpc_out, &rpc_output).expect("failed to write RPC output");
        eprintln!("Written RPC methods to: {}", rpc_out.display());

        if let Some(ffi_rpc_out) = ffi_rpc_out_path {
            let public_rpc_output =
                generate_public_rpc_methods(&rpc_methods, &all_known, &rpc_param_types);
            std::fs::write(&ffi_rpc_out, &public_rpc_output)
                .expect("failed to write public RPC output");
            eprintln!("Written public RPC methods to: {}", ffi_rpc_out.display());
        }
    }
}

fn collect_public_items(
    path: &PathBuf,
    structs: &mut BTreeMap<String, StructDef>,
    enums: &mut BTreeMap<String, EnumDef>,
) {
    let source = std::fs::read_to_string(path)
        .unwrap_or_else(|_| panic!("failed to read upstream file: {}", path.display()));
    let file = syn::parse_file(&source)
        .unwrap_or_else(|_| panic!("failed to parse upstream file: {}", path.display()));

    for item in &file.items {
        match item {
            Item::Struct(s) if is_pub(&s.vis) => {
                if let Some(def) = extract_struct(s) {
                    structs.entry(def.name.clone()).or_insert(def);
                }
            }
            Item::Enum(e) if is_pub(&e.vis) => {
                if let Some(def) = extract_enum(e) {
                    enums.entry(def.name.clone()).or_insert(def);
                }
            }
            _ => {}
        }
    }
}

fn collect_selected_public_items(
    path: &PathBuf,
    selected_names: &[&str],
    structs: &mut BTreeMap<String, StructDef>,
    enums: &mut BTreeMap<String, EnumDef>,
) {
    let selected: BTreeSet<&str> = selected_names.iter().copied().collect();
    let source = std::fs::read_to_string(path)
        .unwrap_or_else(|_| panic!("failed to read upstream file: {}", path.display()));
    let file = syn::parse_file(&source)
        .unwrap_or_else(|_| panic!("failed to parse upstream file: {}", path.display()));

    for item in &file.items {
        match item {
            Item::Struct(s) if is_pub(&s.vis) => {
                let name = s.ident.to_string();
                if selected.contains(name.as_str()) {
                    if let Some(def) = extract_struct(s) {
                        structs.entry(def.name.clone()).or_insert(def);
                    }
                }
            }
            Item::Enum(e) if is_pub(&e.vis) => {
                let name = e.ident.to_string();
                if selected.contains(name.as_str()) {
                    if let Some(def) = extract_enum(e) {
                        enums.entry(def.name.clone()).or_insert(def);
                    }
                }
            }
            _ => {}
        }
    }
}

fn is_pub(vis: &Visibility) -> bool {
    matches!(vis, Visibility::Public(_))
}

fn extract_serde_attrs(attrs: &[syn::Attribute]) -> SerdeAttrs {
    let mut out = SerdeAttrs::default();

    for attr in attrs {
        if !attr.path().is_ident("serde") {
            continue;
        }

        let _ = attr.parse_nested_meta(|meta| {
            if meta.path.is_ident("default") {
                out.default = true;
                return Ok(());
            }

            if meta.path.is_ident("flatten") {
                out.flatten = true;
                return Ok(());
            }

            if meta.path.is_ident("rename_all") {
                let value = meta.value()?;
                let lit: LitStr = value.parse()?;
                out.rename_all = Some(lit.value());
                return Ok(());
            }

            if meta.path.is_ident("rename") {
                let value = meta.value()?;
                let lit: LitStr = value.parse()?;
                out.rename = Some(lit.value());
                return Ok(());
            }

            if meta.path.is_ident("tag") {
                let value = meta.value()?;
                let lit: LitStr = value.parse()?;
                out.tag = Some(lit.value());
                return Ok(());
            }

            Ok(())
        });
    }

    out
}

fn has_default_attr(attrs: &[syn::Attribute]) -> bool {
    attrs.iter().any(|attr| attr.path().is_ident("default"))
}

#[derive(Debug)]
struct FieldDef {
    name: String,
    ty: String,
    serde_default: bool,
    serde_flatten: bool,
    serde_rename: Option<String>,
}

#[derive(Debug)]
struct StructDef {
    name: String,
    fields: Vec<FieldDef>,
    serde_rename_all: Option<String>,
}

#[derive(Debug)]
struct EnumVariantDef {
    name: String,
    fields: Vec<FieldDef>,
    field_style: VariantFieldStyle,
    serde_rename_all: Option<String>,
    serde_rename: Option<String>,
    default_variant: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum VariantFieldStyle {
    Unit,
    Named,
    Unnamed,
}

#[derive(Debug)]
struct EnumDef {
    name: String,
    variants: Vec<EnumVariantDef>,
    is_simple: bool,
    #[allow(dead_code)]
    is_tagged: bool,
    #[allow(dead_code)]
    tag_field: Option<String>,
    serde_rename_all: Option<String>,
}

#[derive(Debug, Default)]
struct SerdeAttrs {
    rename_all: Option<String>,
    rename: Option<String>,
    tag: Option<String>,
    default: bool,
    flatten: bool,
}

fn extract_struct(s: &syn::ItemStruct) -> Option<StructDef> {
    let name = s.ident.to_string();
    let serde_attrs = extract_serde_attrs(&s.attrs);

    let fields = match &s.fields {
        Fields::Named(named) => named
            .named
            .iter()
            .filter(|f| is_pub(&f.vis))
            .map(|f| {
                let field_name = f.ident.as_ref().unwrap().to_string();
                let ty = type_to_string(&f.ty);
                let field_serde_attrs = extract_serde_attrs(&f.attrs);
                FieldDef {
                    name: field_name,
                    ty,
                    serde_default: field_serde_attrs.default,
                    serde_flatten: field_serde_attrs.flatten,
                    serde_rename: field_serde_attrs.rename,
                }
            })
            .collect(),
        _ => return None,
    };

    Some(StructDef {
        name,
        fields,
        serde_rename_all: serde_attrs.rename_all,
    })
}

fn extract_enum(e: &syn::ItemEnum) -> Option<EnumDef> {
    let name = e.ident.to_string();
    let is_simple = e.variants.iter().all(|v| matches!(v.fields, Fields::Unit));

    let serde_attrs = extract_serde_attrs(&e.attrs);
    let tag_field = serde_attrs.tag.clone();

    let variants = e
        .variants
        .iter()
        .map(|v| {
            let vname = v.ident.to_string();
            let variant_serde_attrs = extract_serde_attrs(&v.attrs);
            let (fields, field_style) = match &v.fields {
                Fields::Named(named) => (
                    named
                        .named
                        .iter()
                        .map(|f| {
                            let field_name = f.ident.as_ref().unwrap().to_string();
                            let ty = type_to_string(&f.ty);
                            let field_serde_attrs = extract_serde_attrs(&f.attrs);
                            FieldDef {
                                name: field_name,
                                ty,
                                serde_default: field_serde_attrs.default,
                                serde_flatten: field_serde_attrs.flatten,
                                serde_rename: field_serde_attrs.rename,
                            }
                        })
                        .collect::<Vec<_>>(),
                    VariantFieldStyle::Named,
                ),
                Fields::Unnamed(unnamed) => (
                    unnamed
                        .unnamed
                        .iter()
                        .enumerate()
                        .map(|(index, f)| {
                            let ty = type_to_string(&f.ty);
                            let field_serde_attrs = extract_serde_attrs(&f.attrs);
                            FieldDef {
                                name: format!("field_{index}"),
                                ty,
                                serde_default: field_serde_attrs.default,
                                serde_flatten: field_serde_attrs.flatten,
                                serde_rename: field_serde_attrs.rename,
                            }
                        })
                        .collect::<Vec<_>>(),
                    VariantFieldStyle::Unnamed,
                ),
                Fields::Unit => (vec![], VariantFieldStyle::Unit),
            };
            EnumVariantDef {
                name: vname,
                fields,
                field_style,
                serde_rename_all: variant_serde_attrs.rename_all,
                serde_rename: variant_serde_attrs.rename,
                default_variant: has_default_attr(&v.attrs),
            }
        })
        .collect();

    Some(EnumDef {
        name,
        variants,
        is_simple,
        is_tagged: tag_field.is_some(),
        tag_field,
        serde_rename_all: serde_attrs.rename_all,
    })
}

fn type_to_string(ty: &Type) -> String {
    quote::quote!(#ty).to_string()
}

/// Collect type names referenced by a type string that exist in `known`.
fn collect_referenced_types(ty: &str, known: &BTreeSet<String>, out: &mut BTreeSet<String>) {
    let ty = ty.trim();

    // Unwrap generics.
    for wrapper in &["Box", "Arc", "Option", "Vec"] {
        let prefix1 = format!("{} <", wrapper);
        let prefix2 = format!("{}<", wrapper);
        if ty.starts_with(&prefix1) || ty.starts_with(&prefix2) {
            let inner = strip_wrapper(ty, wrapper);
            collect_referenced_types(&inner, known, out);
            return;
        }
    }

    // HashMap/BTreeMap — check value type.
    if ty.contains("HashMap") || ty.contains("BTreeMap") {
        // Try to extract value type from "HashMap < K , V >"
        if let Some(comma) = ty.find(',') {
            let rest = &ty[comma + 1..];
            let value_ty = rest.trim().trim_end_matches('>').trim();
            collect_referenced_types(value_ty, known, out);
        }
        return;
    }

    // If this is a known type name, include it.
    if let Some(resolved) = resolve_known_type_name(ty, known) {
        out.insert(resolved);
    }
}

fn resolve_known_type_name(ty: &str, known: &BTreeSet<String>) -> Option<String> {
    let trimmed = ty.trim();
    if known.contains(trimmed) {
        return Some(trimmed.to_string());
    }

    let last_segment = trimmed.split("::").last().map(str::trim).unwrap_or(trimmed);
    if known.contains(last_segment) {
        return Some(last_segment.to_string());
    }

    if let Some(stripped) = last_segment.strip_prefix("Core") {
        if known.contains(stripped) {
            return Some(stripped.to_string());
        }
    }

    None
}

fn expand_type_closure(
    mut roots: BTreeSet<String>,
    structs: &BTreeMap<String, StructDef>,
    enums: &BTreeMap<String, EnumDef>,
    known: &BTreeSet<String>,
) -> BTreeSet<String> {
    loop {
        let mut new_types: BTreeSet<String> = BTreeSet::new();
        for name in &roots {
            if let Some(def) = structs.get(name) {
                for field in &def.fields {
                    collect_referenced_types(&field.ty, known, &mut new_types);
                }
            }
            if let Some(def) = enums.get(name) {
                for variant in &def.variants {
                    for field in &variant.fields {
                        collect_referenced_types(&field.ty, known, &mut new_types);
                    }
                }
            }
        }
        let before = roots.len();
        roots.extend(new_types);
        if roots.len() == before {
            break;
        }
    }
    roots
}

/// Map upstream Rust types to UniFFI-compatible mobile types.
/// Known struct/enum names are referenced directly instead of being flattened to String.
/// Excluded types (hand-maintained) are mapped to String.
#[derive(Debug, Clone)]
struct MapFieldDef {
    entry_name: String,
    deserialize_fn: String,
    serialize_fn: String,
    key_ty: String,
    value_mapped_ty: String,
    optional: bool,
}

fn unwrap_option_type(ty: &str) -> (bool, String) {
    let ty = ty.trim();
    if ty.starts_with("Option <") || ty.starts_with("Option<") {
        (true, strip_wrapper(ty, "Option"))
    } else {
        (false, ty.to_string())
    }
}

fn split_top_level_generic_args(input: &str) -> Vec<String> {
    let mut args = Vec::new();
    let mut depth = 0i32;
    let mut start = 0usize;
    for (idx, ch) in input.char_indices() {
        match ch {
            '<' => depth += 1,
            '>' => depth -= 1,
            ',' if depth == 0 => {
                args.push(input[start..idx].trim().to_string());
                start = idx + 1;
            }
            _ => {}
        }
    }
    if start < input.len() {
        args.push(input[start..].trim().to_string());
    }
    args
}

fn parse_map_types(ty: &str) -> Option<(String, String, String)> {
    let ty = ty.trim();
    let prefixes = [
        "HashMap <",
        "HashMap<",
        "BTreeMap <",
        "BTreeMap<",
        "std :: collections :: HashMap <",
        "std :: collections :: HashMap<",
        "std :: collections :: BTreeMap <",
        "std :: collections :: BTreeMap<",
    ];
    let prefix = prefixes.iter().find(|prefix| ty.starts_with(**prefix))?;
    let kind = if prefix.contains("BTreeMap") {
        "BTreeMap"
    } else {
        "HashMap"
    };
    let mut inner = ty[prefix.len()..].trim().to_string();
    if inner.ends_with('>') {
        inner.pop();
    }
    let args = split_top_level_generic_args(&inner);
    if args.len() != 2 {
        return None;
    }
    Some((kind.to_string(), args[0].clone(), args[1].clone()))
}

fn to_pascal_case(s: &str) -> String {
    s.split('_')
        .filter(|part| !part.is_empty())
        .map(|part| {
            let mut chars = part.chars();
            match chars.next() {
                Some(first) => {
                    let mut segment = String::new();
                    segment.push(first.to_ascii_uppercase());
                    segment.push_str(chars.as_str());
                    segment
                }
                None => String::new(),
            }
        })
        .collect()
}

fn map_field_def(
    owner: &str,
    field_name: &str,
    ty: &str,
    known: &BTreeSet<String>,
) -> Option<MapFieldDef> {
    let (optional, inner) = unwrap_option_type(ty);
    let (_kind, key_ty, value_ty) = parse_map_types(&inner)?;
    let owner_base = owner.replace("::", "");
    let field_base = to_pascal_case(field_name);
    let helper_base = format!("{}_{}", to_snake_case(&owner_base), to_snake_case(&field_base));
    Some(MapFieldDef {
        entry_name: format!("{owner_base}{field_base}Entry"),
        deserialize_fn: format!("deserialize_{helper_base}_map"),
        serialize_fn: format!("serialize_{helper_base}_map"),
        key_ty,
        value_mapped_ty: map_type(&value_ty, known),
        optional,
    })
}

fn map_type_for_field(owner: &str, field_name: &str, ty: &str, known: &BTreeSet<String>) -> String {
    if let Some(def) = map_field_def(owner, field_name, ty, known) {
        return if def.optional {
            format!("Option<Vec<{}>>", def.entry_name)
        } else {
            format!("Vec<{}>", def.entry_name)
        };
    }
    map_type(ty, known)
}

fn map_type(ty: &str, known: &BTreeSet<String>) -> String {
    let ty = ty.trim();
    match ty {
        // Primitives
        "String" => "String".to_string(),
        "bool" => "bool".to_string(),
        "i8" | "i16" | "i32" => "i32".to_string(),
        "i64" => "i64".to_string(),
        "u8" | "u16" | "u32" => "u32".to_string(),
        "u64" => "u64".to_string(),
        "f32" | "f64" => "f64".to_string(),
        "usize" => "u64".to_string(),

        // Path types → typed absolute path wrapper
        "PathBuf" | "std :: path :: PathBuf" | "AbsolutePathBuf" => "AbsolutePath".to_string(),

        // Dynamic JSON / IDs → typed wrappers
        "Value" | "serde_json :: Value" | "JsonValue" => "JsonValue".to_string(),
        "RequestId" => "RequestId".to_string(),

        // Wrapper types → unwrap
        _ if ty.starts_with("Box <") || ty.starts_with("Box<") => {
            let inner = strip_wrapper(ty, "Box");
            map_type(&inner, known)
        }
        _ if ty.starts_with("Arc <") || ty.starts_with("Arc<") => {
            let inner = strip_wrapper(ty, "Arc");
            map_type(&inner, known)
        }

        // Option<T> → Option<mapped(T)>
        _ if ty.starts_with("Option <") || ty.starts_with("Option<") => {
            let inner = strip_wrapper(ty, "Option");
            let mapped = map_type(&inner, known);
            format!("Option<{}>", mapped)
        }

        // Vec<T> → Vec<mapped(T)>
        _ if ty.starts_with("Vec <") || ty.starts_with("Vec<") => {
            let inner = strip_wrapper(ty, "Vec");
            format!("Vec<{}>", map_type(&inner, known))
        }

        // Maps are handled at the field level so they can round-trip through typed entry wrappers.
        _ if ty.contains("HashMap") || ty.contains("BTreeMap") => "String".to_string(),

        _ => {
            // If the type is a known upstream struct/enum, reference it directly.
            if let Some(resolved) = resolve_known_type_name(ty, known) {
                resolved
            } else {
                // Truly unknown (imported from other crates) → String
                "String".to_string()
            }
        }
    }
}

/// Strip a generic wrapper like `Box<T>` or `Option<T>` to get the inner type.
fn strip_wrapper(ty: &str, wrapper: &str) -> String {
    let prefixes = [format!("{} <", wrapper), format!("{}<", wrapper)];
    let mut inner = ty.to_string();
    for prefix in &prefixes {
        if inner.starts_with(prefix) {
            inner = inner[prefix.len()..].to_string();
            break;
        }
    }
    if inner.ends_with('>') {
        inner.pop();
    }
    inner.trim().to_string()
}

fn generate_wrapper_struct(def: &StructDef, known: &BTreeSet<String>) -> String {
    let mut out = String::new();

    out.push_str(&format!(
        "/// Mobile wrapper for upstream `{}`.\n",
        def.name
    ));
    out.push_str("#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]\n");
    if let Some(rename_all) = &def.serde_rename_all {
        out.push_str(&format!("#[serde(rename_all = \"{}\")]\n", rename_all));
    }

    // All generated structs get uniffi::Record so they can cross the FFI boundary
    // as typed values, including params records for the public direct-RPC surface.
    out.push_str("#[derive(uniffi::Record)]\n");

    out.push_str(&format!("pub struct {} {{\n", def.name));

    for field in &def.fields {
        let mapped = map_type_for_field(&def.name, &field.name, &field.ty, known);
        push_field_serde_attrs(&mut out, "    ", &def.name, field, known);
        out.push_str(&format!("    pub {}: {},\n", field.name, mapped));
    }

    out.push_str("}\n");
    out
}

fn generate_wrapper_enum(def: &EnumDef, known: &BTreeSet<String>) -> String {
    let mut out = String::new();
    let has_default_variant = def.variants.iter().any(|variant| variant.default_variant);

    out.push_str(&format!(
        "/// Mobile wrapper for upstream `{}`.\n",
        def.name
    ));

    if def.is_simple {
        // Simple enum — all unit variants.
        if has_default_variant {
            out.push_str("#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]\n");
        } else {
            out.push_str("#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]\n");
        }
        // Add serde tag + rename_all if the upstream enum has them.
        if let Some(tag) = &def.tag_field {
            if let Some(rename_all) = &def.serde_rename_all {
                out.push_str(&format!(
                    "#[serde(tag = \"{}\", rename_all = \"{}\")]\n",
                    tag, rename_all
                ));
            } else {
                out.push_str(&format!("#[serde(tag = \"{}\")]\n", tag));
            }
        } else if let Some(rename_all) = &def.serde_rename_all {
            out.push_str(&format!("#[serde(rename_all = \"{}\")]\n", rename_all));
        }
        out.push_str("#[derive(uniffi::Enum)]\n");
        out.push_str(&format!("pub enum {} {{\n", def.name));
        for variant in &def.variants {
            if variant.default_variant {
                out.push_str("    #[default]\n");
            }
            if let Some(rename) = &variant.serde_rename {
                out.push_str(&format!("    #[serde(rename = \"{}\")]\n", rename));
            }
            out.push_str(&format!("    {},\n", variant.name));
        }
        out.push_str("}\n");
    } else {
        // Enum with associated data — generate as uniffi::Enum with named fields.
        if has_default_variant {
            out.push_str("#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]\n");
        } else {
            out.push_str("#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]\n");
        }
        // Add serde tag + rename_all if the upstream enum has them.
        if let Some(tag) = &def.tag_field {
            if let Some(rename_all) = &def.serde_rename_all {
                out.push_str(&format!(
                    "#[serde(tag = \"{}\", rename_all = \"{}\")]\n",
                    tag, rename_all
                ));
            } else {
                out.push_str(&format!("#[serde(tag = \"{}\")]\n", tag));
            }
        } else if let Some(rename_all) = &def.serde_rename_all {
            out.push_str(&format!("#[serde(rename_all = \"{}\")]\n", rename_all));
        }
        out.push_str("#[derive(uniffi::Enum)]\n");
        out.push_str(&format!("pub enum {} {{\n", def.name));
        for variant in &def.variants {
            if variant.default_variant {
                out.push_str("    #[default]\n");
            }
            if let Some(rename) = &variant.serde_rename {
                out.push_str(&format!("    #[serde(rename = \"{}\")]\n", rename));
            }
            if let Some(rename_all) = &variant.serde_rename_all {
                out.push_str(&format!("    #[serde(rename_all = \"{}\")]\n", rename_all));
            }
            if variant.fields.is_empty() {
                out.push_str(&format!("    {},\n", variant.name));
            } else if variant.field_style == VariantFieldStyle::Named {
                out.push_str(&format!("    {} {{\n", variant.name));
                for field in &variant.fields {
                    let mapped = map_type_for_field(&def.name, &field.name, &field.ty, known);
                    push_field_serde_attrs(&mut out, "        ", &def.name, field, known);
                    out.push_str(&format!("        {}: {},\n", field.name, mapped));
                }
                out.push_str("    },\n");
            } else {
                let field_types: Vec<String> = variant
                    .fields
                    .iter()
                    .map(|field| map_type(&field.ty, known))
                    .collect();
                out.push_str(&format!(
                    "    {}({}),\n",
                    variant.name,
                    field_types.join(", ")
                ));
            }
        }
        out.push_str("}\n");
    }

    out
}

fn push_field_serde_attrs(
    out: &mut String,
    indent: &str,
    owner: &str,
    field: &FieldDef,
    known: &BTreeSet<String>,
) {
    if let Some(map_def) = map_field_def(owner, &field.name, &field.ty, known) {
        out.push_str(&format!(
            "{indent}#[serde(deserialize_with = \"{}\", serialize_with = \"{}\")]\n",
            map_def.deserialize_fn, map_def.serialize_fn
        ));
    }
    if field.serde_default {
        out.push_str(&format!("{indent}#[serde(default)]\n"));
    }
    if field.serde_flatten {
        out.push_str(&format!("{indent}#[serde(flatten)]\n"));
    }
    if let Some(rename) = &field.serde_rename {
        out.push_str(&format!("{indent}#[serde(rename = \"{}\")]\n", rename));
    }
}

fn to_snake_case(s: &str) -> String {
    let mut result = String::new();
    for (i, c) in s.chars().enumerate() {
        if c.is_uppercase() && i > 0 {
            result.push('_');
        }
        result.push(c.to_lowercase().next().unwrap());
    }
    result
}

// ---------------------------------------------------------------------------
// RPC method generation from common.rs ClientRequest variants
// ---------------------------------------------------------------------------

#[derive(Debug)]
struct RpcMethod {
    variant: String,       // e.g. "ThreadRealtimeStop"
    wire_method: String,   // e.g. "thread/realtime/stop"
    params_type: String,   // e.g. "v2::ThreadRealtimeStopParams" or "Option<()>"
    response_type: String, // e.g. "v2::ThreadRealtimeStopResponse"
}

/// Parse ClientRequest variants from common.rs using regex.
fn parse_client_requests(source: &str) -> Vec<RpcMethod> {
    let mut methods = Vec::new();
    let client_block_start = source.find("client_request_definitions! {").unwrap_or(0);
    let client_block_end = source
        .find("server_request_definitions! {")
        .unwrap_or(source.len());
    let source = &source[client_block_start..client_block_end];
    let re = regex::Regex::new(
        r#"(?m)^\s+(\w+)(?:\s*=>\s*"([^"]+)")?\s*\{\s*\n\s*params:\s*(?:#\[.*?\]\s*)*(\S+),?\s*\n(?:\s*inspect_params:\s*\w+,?\s*\n)?\s*response:\s*(\S+),?"#
    ).unwrap();

    for cap in re.captures_iter(source) {
        let variant = cap[1].to_string();
        methods.push(RpcMethod {
            wire_method: cap
                .get(2)
                .map(|value| value.as_str().to_string())
                .unwrap_or_else(|| variant.clone()),
            variant,
            params_type: cap[3].trim_end_matches(',').to_string(),
            response_type: cap[4].trim_end_matches(',').to_string(),
        });
    }
    methods
}

/// Generate internal typed RPC helpers for `MobileClient`.
fn generate_rpc_methods(
    methods: &[RpcMethod],
    known: &BTreeSet<String>,
    rpc_param_types: &BTreeSet<String>,
    structs: &BTreeMap<String, StructDef>,
    enums: &BTreeMap<String, EnumDef>,
) -> String {
    let supported: BTreeSet<&str> = SUPPORTED_RPC_VARIANTS.iter().copied().collect();
    let mut out = String::new();
    out.push_str("//! Auto-generated internal typed RPC helpers for MobileClient.\n");
    out.push_str("//!\n");
    out.push_str("//! DO NOT EDIT — regenerate with: cargo run -p codex-mobile-codegen -- --rpc-out <path>\n\n");
    out.push_str("use codex_app_server_protocol as upstream;\n");
    out.push_str("use crate::{MobileClient, types::generated};\n");
    out.push_str("use super::{RpcClientError, next_request_id};\n\n");
    out.push_str(
        "pub(crate) fn convert_generated_field<T, U>(value: T) -> Result<U, RpcClientError>\n",
    );
    out.push_str("where\n");
    out.push_str("    T: serde::Serialize,\n");
    out.push_str("    U: serde::de::DeserializeOwned,\n");
    out.push_str("{\n");
    out.push_str("    let value = serde_json::to_value(value)\n");
    out.push_str("        .map_err(|e| RpcClientError::Serialization(format!(\"serialize generated field value: {e}\")))?;\n");
    out.push_str("    #[cfg(feature = \"rpc-trace\")]\n");
    out.push_str("    {\n");
    out.push_str("        let src = std::any::type_name::<T>();\n");
    out.push_str("        let dst = std::any::type_name::<U>();\n");
    out.push_str("        eprintln!(\"[codex-rpc] convert {src} -> {dst}\");\n");
    out.push_str("    }\n");
    out.push_str("    serde_json::from_value(value.clone()).map_err(|e| {\n");
    out.push_str("        #[cfg(feature = \"rpc-trace\")]\n");
    out.push_str("        {\n");
    out.push_str("            let src = std::any::type_name::<T>();\n");
    out.push_str("            let dst = std::any::type_name::<U>();\n");
    out.push_str("            let json = serde_json::to_string_pretty(&value).unwrap_or_default();\n");
    out.push_str("            eprintln!(\n");
    out.push_str("                \"[codex-rpc] FAILED {src} -> {dst}: {e}\\n--- intermediate JSON ---\\n{json}\\n---\"\n");
    out.push_str("            );\n");
    out.push_str("        }\n");
    out.push_str("        RpcClientError::Serialization(format!(\"deserialize upstream field value: {e}\"))\n");
    out.push_str("    })\n");
    out.push_str("}\n\n");

    out.push_str("/// Auto-generated typed RPC helpers.\n");
    out.push_str(
        "/// Each helper converts a generated params wrapper into the upstream request type\n",
    );
    out.push_str("/// and sends it via `request_typed_for_server`.\n\n");

    let direct_param_conversion_types: BTreeSet<String> = PARAM_ROOT_TYPES
        .iter()
        .filter(|name| rpc_param_types.contains(**name))
        .map(|name| (*name).to_string())
        .collect();

    let mut rpc_type_names: Vec<String> = direct_param_conversion_types.iter().cloned().collect();
    rpc_type_names.sort();
    for name in rpc_type_names {
        if EXCLUDED_GENERATED_TYPES.contains(&name.as_str()) {
            continue;
        }
        if DIRECT_CONVERSION_SKIP_TYPES.contains(&name.as_str()) {
            continue;
        }
        if let Some(def) = structs.get(&name) {
            out.push_str(&generate_try_from_struct(def));
            out.push('\n');
        } else if let Some(def) = enums.get(&name) {
            out.push_str(&generate_try_from_enum(def));
            out.push('\n');
        }
    }

    out.push_str("impl MobileClient {\n");

    for method in methods {
        if !supported.contains(method.variant.as_str()) {
            continue;
        }

        let has_params = method.params_type != "Option<()>";
        let params_struct_name = method
            .params_type
            .trim_start_matches("v1::")
            .replace("v2::", "")
            .replace("codex_app_server_protocol::", "");
        let method_name = format!("generated_{}", to_snake_case(&method.variant));
        let response_type = method
            .response_type
            .trim_start_matches("v1::")
            .replace("v2::", "")
            .replace("codex_app_server_protocol::", "");

        if !known.contains(&response_type) {
            eprintln!(
                "  SKIP {} — response type {} not found in generated set",
                method.variant, response_type
            );
            continue;
        }

        out.push_str(&format!(
            "\n    /// `{}` — auto-generated typed RPC.\n",
            method.wire_method
        ));
        out.push_str(&format!("    pub(crate) async fn {}(\n", method_name));
        out.push_str("        &self,\n");
        out.push_str("        server_id: &str,\n");
        if has_params {
            if !known.contains(&params_struct_name) {
                eprintln!(
                    "  SKIP {} — params type {} not found in generated set",
                    method.variant, params_struct_name
                );
                out.push_str("    ) -> Result<(), RpcClientError> {\n");
                out.push_str(
                    "        unreachable!(\"generator emitted an invalid method stub\")\n",
                );
                out.push_str("    }\n");
                continue;
            }
            out.push_str(&format!(
                "        params: generated::{},\n",
                params_struct_name
            ));
        }
        out.push_str(&format!(
            "    ) -> Result<generated::{}, RpcClientError> {{\n",
            response_type
        ));

        if has_params {
            out.push_str(&format!(
                "        let params: upstream::{} = params.try_into()?;\n",
                params_struct_name
            ));
            out.push_str(&format!(
                "        let req = upstream::ClientRequest::{} {{\n",
                method.variant
            ));
            out.push_str("            request_id: upstream::RequestId::Integer(next_request_id()),\n");
            out.push_str("            params,\n");
            out.push_str("        };\n");
        } else {
            out.push_str(&format!(
                "        let req = upstream::ClientRequest::{} {{\n",
                method.variant
            ));
            out.push_str("            request_id: upstream::RequestId::Integer(next_request_id()),\n");
            out.push_str("            params: None,\n");
            out.push_str("        };\n");
        }

        out.push_str("        self.request_typed_for_server(server_id, req)\n");
        out.push_str("            .await\n");
        out.push_str("            .map_err(RpcClientError::Rpc)\n");
        out.push_str("    }\n");
    }

    out.push_str("}\n");
    out
}

fn generate_public_rpc_methods(
    methods: &[RpcMethod],
    known: &BTreeSet<String>,
    rpc_param_types: &BTreeSet<String>,
) -> String {
    let supported: BTreeSet<&str> = SUPPORTED_RPC_VARIANTS.iter().copied().collect();
    let mut out = String::new();
    out.push_str("//! Auto-generated public UniFFI direct RPC surface.\n");
    out.push_str("//!\n");
    out.push_str(
        "//! DO NOT EDIT — regenerate with: cargo run -p codex-mobile-codegen -- --ffi-rpc-out <path>\n\n",
    );
    out.push_str("use crate::MobileClient;\n");
    out.push_str("use crate::ffi::ClientError;\n");
    out.push_str("use crate::ffi::shared::{blocking_async, shared_mobile_client, shared_runtime};\n");
    out.push_str("use crate::types::generated;\n");
    out.push_str("use std::sync::Arc;\n\n");
    out.push_str("#[derive(uniffi::Object)]\n");
    out.push_str("pub struct AppServerRpc {\n");
    out.push_str("    pub(crate) inner: Arc<MobileClient>,\n");
    out.push_str("    pub(crate) rt: Arc<tokio::runtime::Runtime>,\n");
    out.push_str("}\n\n");
    out.push_str("#[uniffi::export(async_runtime = \"tokio\")]\n");
    out.push_str("impl AppServerRpc {\n");
    out.push_str("    #[uniffi::constructor]\n");
    out.push_str("    pub fn new() -> Self {\n");
    out.push_str("        Self {\n");
    out.push_str("            inner: shared_mobile_client(),\n");
    out.push_str("            rt: shared_runtime(),\n");
    out.push_str("        }\n");
    out.push_str("    }\n");

    for method in methods {
        if !supported.contains(method.variant.as_str()) {
            continue;
        }

        let has_params = method.params_type != "Option<()>";
        let params_struct_name = method
            .params_type
            .trim_start_matches("v1::")
            .replace("v2::", "")
            .replace("codex_app_server_protocol::", "");
        let method_name = to_snake_case(&method.variant);
        let response_type = method
            .response_type
            .trim_start_matches("v1::")
            .replace("v2::", "")
            .replace("codex_app_server_protocol::", "");
        if !known.contains(&response_type) {
            continue;
        }
        if has_params && !known.contains(&params_struct_name) {
            continue;
        }
        if has_params && !rpc_param_types.contains(&params_struct_name) {
            continue;
        }

        out.push_str(&format!(
            "\n    /// Direct `{}` app-server RPC.\n",
            method.wire_method
        ));
        out.push_str(&format!("    pub async fn {}(\n", method_name));
        out.push_str("        &self,\n");
        out.push_str("        server_id: String,\n");
        if has_params {
            out.push_str(&format!(
                "        params: generated::{},\n",
                params_struct_name
            ));
        }
        out.push_str(&format!(
            "    ) -> Result<generated::{}, ClientError> {{\n",
            response_type
        ));
        out.push_str("        blocking_async!(self.rt, self.inner, |c| {\n");
        if has_params {
            out.push_str("            let reconcile_params = params.clone();\n");
            out.push_str(&format!(
                "            let response = c.generated_{}(&server_id, params).await?;\n",
                method_name
            ));
        } else {
            out.push_str(&format!(
                "            let response = c.generated_{}(&server_id).await?;\n",
                method_name
            ));
        }
        if has_params {
            out.push_str(&format!(
                "            c.reconcile_public_rpc(\"{}\", &server_id, Some(&reconcile_params), &response)\n",
                method.wire_method
            ));
        } else {
            out.push_str(&format!(
                "            c.reconcile_public_rpc(\"{}\", &server_id, Option::<&()>::None, &response)\n",
                method.wire_method
            ));
        }
        out.push_str("                .await\n");
        out.push_str("                .map_err(|e| ClientError::Rpc(e.to_string()))?;\n");
        out.push_str("            Ok(response)\n");
        out.push_str("        })\n");
        out.push_str("    }\n");
    }

    out.push_str("}\n");
    out
}
fn generate_try_from_struct(def: &StructDef) -> String {
    let mut out = String::new();
    out.push_str(&format!(
        "impl TryFrom<generated::{}> for upstream::{} {{\n",
        def.name, def.name
    ));
    out.push_str("    type Error = RpcClientError;\n\n");
    out.push_str(&format!(
        "    fn try_from(value: generated::{}) -> Result<Self, Self::Error> {{\n",
        def.name
    ));
    out.push_str("        convert_generated_field(value)\n");
    out.push_str("    }\n");
    out.push_str("}\n");
    out
}

fn generate_try_from_enum(def: &EnumDef) -> String {
    let mut out = String::new();
    out.push_str(&format!(
        "impl TryFrom<generated::{}> for upstream::{} {{\n",
        def.name, def.name
    ));
    out.push_str("    type Error = RpcClientError;\n\n");
    out.push_str(&format!(
        "    fn try_from(value: generated::{}) -> Result<Self, Self::Error> {{\n",
        def.name
    ));
    out.push_str("        convert_generated_field(value)\n");
    out.push_str("    }\n");
    out.push_str("}\n");
    out
}
