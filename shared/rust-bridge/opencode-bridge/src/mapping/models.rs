use serde::{Deserialize, Serialize};

use crate::{OpenCodeProviderAuthMethods, OpenCodeProviderAuthState, OpenCodeProviderCatalog};

use super::OpenCodeMappingScope;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeModelCatalog {
    pub server_id: String,
    pub directory: String,
    pub providers: Vec<OpenCodeProviderProjection>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeProviderProjection {
    pub server_id: String,
    pub directory: String,
    pub provider_id: String,
    pub provider_name: String,
    pub auth_state: OpenCodeProviderAuthState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_model_id: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub models: Vec<OpenCodeModelProjection>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeModelProjection {
    pub provider_id: String,
    pub model_id: String,
    pub name: String,
    pub is_default: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
}

pub fn map_model_catalog(
    scope: &OpenCodeMappingScope,
    catalog: &OpenCodeProviderCatalog,
    auth_methods: Option<&OpenCodeProviderAuthMethods>,
) -> OpenCodeModelCatalog {
    OpenCodeModelCatalog {
        server_id: scope.server_id.clone(),
        directory: scope.directory.clone(),
        providers: catalog
            .all
            .iter()
            .filter(|provider| catalog.connected.iter().any(|id| id == &provider.id))
            .map(|provider| {
                let default_model_id = catalog.default.get(&provider.id).cloned();
                OpenCodeProviderProjection {
                    server_id: scope.server_id.clone(),
                    directory: scope.directory.clone(),
                    provider_id: provider.id.clone(),
                    provider_name: provider.name.clone(),
                    auth_state: catalog.auth_state_for(&provider.id, auth_methods),
                    default_model_id: default_model_id.clone(),
                    models: provider
                        .models
                        .iter()
                        .map(|model| OpenCodeModelProjection {
                            provider_id: model.provider_id.clone(),
                            model_id: model.id.clone(),
                            name: model.name.clone(),
                            is_default: default_model_id
                                .as_deref()
                                .is_some_and(|default| default == model.id),
                            status: model.status.clone(),
                        })
                        .collect(),
                }
            })
            .collect(),
    }
}
