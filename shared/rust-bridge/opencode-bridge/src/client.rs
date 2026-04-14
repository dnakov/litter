use std::time::Duration;

use reqwest::{Method, RequestBuilder, Response, Url};
use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::{
    OpenCodeBridgeError, OpenCodeHealthResponse, OpenCodeMessageList, OpenCodeMessageWithParts,
    OpenCodePathInfo, OpenCodePermissionId, OpenCodePermissionReplyRequest, OpenCodeProjectInfo,
    OpenCodePromptAsyncRequest, OpenCodeProviderAuthMethods, OpenCodeProviderCatalog,
    OpenCodeRequestContext, OpenCodeServerConfig, OpenCodeSession, OpenCodeSessionCreateRequest,
    OpenCodeSessionForkRequest, OpenCodeSessionListQuery, OpenCodeSessionStatusIndex,
    OpenCodeSessionUpdateRequest,
};

const DEFAULT_REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const DIRECTORY_HEADER: &str = "x-opencode-directory";
const WORKSPACE_HEADER: &str = "x-opencode-workspace";

#[derive(Debug, Clone)]
pub struct OpenCodeClient {
    config: OpenCodeServerConfig,
    http: reqwest::Client,
    request_timeout: Duration,
}

impl OpenCodeClient {
    pub fn new(config: OpenCodeServerConfig) -> Result<Self, OpenCodeBridgeError> {
        let request_timeout = DEFAULT_REQUEST_TIMEOUT;
        let http = reqwest::Client::builder()
            .timeout(request_timeout)
            .build()
            .map_err(|source| OpenCodeBridgeError::transport("client.init", source))?;

        Ok(Self {
            config,
            http,
            request_timeout,
        })
    }

    pub fn config(&self) -> &OpenCodeServerConfig {
        &self.config
    }

    pub fn request_timeout(&self) -> Duration {
        self.request_timeout
    }

    pub async fn get_health(&self) -> Result<OpenCodeHealthResponse, OpenCodeBridgeError> {
        self.get_json("global.health", "/global/health").await
    }

    pub async fn get_current_project(
        &self,
        context: &OpenCodeRequestContext,
    ) -> Result<OpenCodeProjectInfo, OpenCodeBridgeError> {
        let builder = self.request(Method::GET, "/project/current")?;
        let builder =
            self.apply_context(Method::GET, builder, Some(context), "project current", true)?;
        self.send_json("project.current", builder).await
    }

    pub async fn get_path_info(
        &self,
        context: &OpenCodeRequestContext,
    ) -> Result<OpenCodePathInfo, OpenCodeBridgeError> {
        let builder = self.request(Method::GET, "/path")?;
        let builder = self.apply_context(Method::GET, builder, Some(context), "path info", true)?;
        self.send_json("path.get", builder).await
    }

    pub async fn list_sessions(
        &self,
        query: &OpenCodeSessionListQuery,
    ) -> Result<Vec<OpenCodeSession>, OpenCodeBridgeError> {
        query.require_directory()?;
        let builder = self.request(Method::GET, "/session")?.query(query);
        self.send_json("session.list", builder).await
    }

    pub async fn get_session(
        &self,
        session_id: &str,
        context: &OpenCodeRequestContext,
    ) -> Result<OpenCodeSession, OpenCodeBridgeError> {
        let builder = self.request(Method::GET, &format!("/session/{session_id}"))?;
        let builder =
            self.apply_context(Method::GET, builder, Some(context), "session get", true)?;
        self.send_json("session.get", builder).await
    }

    pub async fn get_session_status(
        &self,
        context: &OpenCodeRequestContext,
    ) -> Result<OpenCodeSessionStatusIndex, OpenCodeBridgeError> {
        let builder = self.request(Method::GET, "/session/status")?;
        let builder =
            self.apply_context(Method::GET, builder, Some(context), "session status", true)?;
        self.send_json("session.status", builder).await
    }

    pub async fn create_session(
        &self,
        request: &OpenCodeSessionCreateRequest,
    ) -> Result<OpenCodeSession, OpenCodeBridgeError> {
        #[derive(serde::Serialize)]
        #[serde(rename_all = "camelCase")]
        struct Body<'a> {
            #[serde(rename = "parentID", skip_serializing_if = "Option::is_none")]
            parent_id: &'a Option<String>,
            #[serde(skip_serializing_if = "Option::is_none")]
            title: &'a Option<String>,
            #[serde(rename = "workspaceID", skip_serializing_if = "Option::is_none")]
            workspace_id: &'a Option<String>,
        }

        request.require_directory()?;
        let body = Body {
            parent_id: &request.parent_id,
            title: &request.title,
            workspace_id: &request.workspace_id,
        };
        let builder = self.request(Method::POST, "/session")?.json(&body);
        let builder = self.apply_context(
            Method::POST,
            builder,
            Some(&request.context),
            "session create",
            true,
        )?;
        self.send_json("session.create", builder).await
    }

    pub async fn list_messages(
        &self,
        session_id: &str,
        context: &OpenCodeRequestContext,
        limit: Option<u32>,
        before: Option<&str>,
    ) -> Result<OpenCodeMessageList, OpenCodeBridgeError> {
        #[derive(serde::Serialize)]
        struct Query<'a> {
            limit: Option<u32>,
            before: Option<&'a str>,
        }

        let builder = self.request(Method::GET, &format!("/session/{session_id}/message"))?;
        let builder = builder.query(&Query { limit, before });
        let builder =
            self.apply_context(Method::GET, builder, Some(context), "message list", true)?;
        let response = self.send("session.messages", builder).await?;
        let next_cursor = response
            .headers()
            .get("x-next-cursor")
            .and_then(|value| value.to_str().ok())
            .map(ToOwned::to_owned);
        let items = self
            .decode_json::<Vec<OpenCodeMessageWithParts>>("session.messages", response)
            .await?;
        Ok(OpenCodeMessageList { items, next_cursor })
    }

    pub async fn prompt_async(
        &self,
        session_id: &str,
        context: &OpenCodeRequestContext,
        body: &OpenCodePromptAsyncRequest,
    ) -> Result<(), OpenCodeBridgeError> {
        let builder = self
            .request(Method::POST, &format!("/session/{session_id}/prompt_async"))?
            .json(body);
        let builder =
            self.apply_context(Method::POST, builder, Some(context), "session prompt", true)?;
        self.send_no_content("session.prompt_async", builder).await
    }

    pub async fn abort_session(
        &self,
        session_id: &str,
        context: &OpenCodeRequestContext,
    ) -> Result<bool, OpenCodeBridgeError> {
        let builder = self.request(Method::POST, &format!("/session/{session_id}/abort"))?;
        let builder =
            self.apply_context(Method::POST, builder, Some(context), "session abort", true)?;
        self.send_json("session.abort", builder).await
    }

    pub async fn fork_session(
        &self,
        session_id: &str,
        context: &OpenCodeRequestContext,
        request: &OpenCodeSessionForkRequest,
    ) -> Result<OpenCodeSession, OpenCodeBridgeError> {
        let builder = self
            .request(Method::POST, &format!("/session/{session_id}/fork"))?
            .json(request);
        let builder =
            self.apply_context(Method::POST, builder, Some(context), "session fork", true)?;
        self.send_json("session.fork", builder).await
    }

    pub async fn rename_session(
        &self,
        session_id: &str,
        context: &OpenCodeRequestContext,
        request: &OpenCodeSessionUpdateRequest,
    ) -> Result<OpenCodeSession, OpenCodeBridgeError> {
        let builder = self
            .request(Method::PATCH, &format!("/session/{session_id}"))?
            .json(request);
        let builder = self.apply_context(
            Method::PATCH,
            builder,
            Some(context),
            "session rename",
            true,
        )?;
        self.send_json("session.update", builder).await
    }

    pub async fn list_providers(
        &self,
        context: &OpenCodeRequestContext,
    ) -> Result<OpenCodeProviderCatalog, OpenCodeBridgeError> {
        let builder = self.request(Method::GET, "/provider")?;
        let builder =
            self.apply_context(Method::GET, builder, Some(context), "provider list", true)?;
        self.send_json("provider.list", builder).await
    }

    pub async fn list_provider_auth_methods(
        &self,
        context: &OpenCodeRequestContext,
    ) -> Result<OpenCodeProviderAuthMethods, OpenCodeBridgeError> {
        let builder = self.request(Method::GET, "/provider/auth")?;
        let builder = self.apply_context(
            Method::GET,
            builder,
            Some(context),
            "provider auth methods",
            true,
        )?;
        self.send_json("provider.auth", builder).await
    }

    pub async fn reply_permission(
        &self,
        session_id: &str,
        permission_id: &OpenCodePermissionId,
        context: &OpenCodeRequestContext,
        request: &OpenCodePermissionReplyRequest,
    ) -> Result<bool, OpenCodeBridgeError> {
        let builder = self
            .request(
                Method::POST,
                &format!("/session/{session_id}/permissions/{}", permission_id.0),
            )?
            .json(request);
        let builder = self.apply_context(
            Method::POST,
            builder,
            Some(context),
            "permission reply",
            true,
        )?;
        self.send_json("permission.respond", builder).await
    }

    fn request(&self, method: Method, path: &str) -> Result<RequestBuilder, OpenCodeBridgeError> {
        let url = self.endpoint_url(path)?;
        let mut builder = self.http.request(method, url);

        if let Some(password) = self.config.basic_auth_password.as_deref() {
            let username = self
                .config
                .basic_auth_username
                .as_deref()
                .unwrap_or("opencode");
            builder = builder.basic_auth(username, Some(password));
        }

        Ok(builder)
    }

    fn endpoint_url(&self, path: &str) -> Result<Url, OpenCodeBridgeError> {
        let mut url = self.config.base_url.clone();
        let base_path = url.path().trim_end_matches('/');
        let full_path = if base_path.is_empty() {
            format!("/{}", path.trim_start_matches('/'))
        } else {
            format!("{base_path}/{}", path.trim_start_matches('/'))
        };
        url.set_path(&full_path);
        Ok(url)
    }

    fn apply_context(
        &self,
        method: Method,
        builder: RequestBuilder,
        context: Option<&OpenCodeRequestContext>,
        operation: &'static str,
        require_directory: bool,
    ) -> Result<RequestBuilder, OpenCodeBridgeError> {
        let mut builder = builder;

        let context = match context {
            Some(context) => context,
            None if require_directory => {
                return Err(OpenCodeBridgeError::MissingDirectory { operation });
            }
            None => return Ok(builder),
        };

        if require_directory {
            context.require_directory_for(operation)?;
        } else if context
            .directory
            .as_deref()
            .is_some_and(|value| value.trim().is_empty())
        {
            return Err(OpenCodeBridgeError::EmptyDirectory { operation });
        }

        builder = builder.query(context);

        if method != Method::GET && method != Method::HEAD {
            if let Some(directory) = context.directory.as_deref() {
                builder = builder.header(DIRECTORY_HEADER, directory);
            }
            if let Some(workspace) = context.workspace.as_deref() {
                builder = builder.header(WORKSPACE_HEADER, workspace);
            }
        }

        Ok(builder)
    }

    async fn get_json<T>(
        &self,
        endpoint: &'static str,
        path: &str,
    ) -> Result<T, OpenCodeBridgeError>
    where
        T: DeserializeOwned,
    {
        let builder = self.request(Method::GET, path)?;
        self.send_json(endpoint, builder).await
    }

    async fn send_json<T>(
        &self,
        endpoint: &'static str,
        builder: RequestBuilder,
    ) -> Result<T, OpenCodeBridgeError>
    where
        T: DeserializeOwned,
    {
        let response = self.send(endpoint, builder).await?;
        self.decode_json(endpoint, response).await
    }

    async fn send_no_content(
        &self,
        endpoint: &'static str,
        builder: RequestBuilder,
    ) -> Result<(), OpenCodeBridgeError> {
        let response = self.send(endpoint, builder).await?;
        let _ = response
            .bytes()
            .await
            .map_err(|source| OpenCodeBridgeError::transport(endpoint, source))?;
        Ok(())
    }

    async fn send(
        &self,
        endpoint: &'static str,
        builder: RequestBuilder,
    ) -> Result<Response, OpenCodeBridgeError> {
        let response = builder
            .send()
            .await
            .map_err(|source| OpenCodeBridgeError::transport(endpoint, source))?;

        if response.status().is_success() {
            return Ok(response);
        }

        Err(self.normalize_status_error(endpoint, response).await)
    }

    async fn decode_json<T>(
        &self,
        endpoint: &'static str,
        response: Response,
    ) -> Result<T, OpenCodeBridgeError>
    where
        T: DeserializeOwned,
    {
        let body = response
            .bytes()
            .await
            .map_err(|source| OpenCodeBridgeError::transport(endpoint, source))?;
        serde_json::from_slice::<T>(&body).map_err(|source| {
            OpenCodeBridgeError::invalid_response(
                endpoint,
                Some(truncate_for_error(String::from_utf8_lossy(&body).as_ref())),
                source,
            )
        })
    }

    async fn normalize_status_error(
        &self,
        endpoint: &'static str,
        response: Response,
    ) -> OpenCodeBridgeError {
        let status = response.status();
        let body = response
            .text()
            .await
            .ok()
            .map(|body| truncate_for_error(&body));
        let message = body
            .as_deref()
            .and_then(extract_error_message)
            .unwrap_or_else(|| format!("request failed with status {status}"));
        OpenCodeBridgeError::status(endpoint, status, message, body)
    }
}

fn extract_error_message(body: &str) -> Option<String> {
    let parsed = serde_json::from_str::<Value>(body).ok()?;
    let direct = parsed.get("message").and_then(Value::as_str);
    let nested = parsed
        .get("error")
        .and_then(|value| value.get("message"))
        .and_then(Value::as_str);
    let named = parsed.get("name").and_then(Value::as_str);

    direct
        .or(nested)
        .or(named)
        .map(|message| truncate_for_error(message))
}

fn truncate_for_error(input: &str) -> String {
    const MAX_LEN: usize = 2_048;
    if input.len() <= MAX_LEN {
        return input.to_string();
    }

    let mut truncated = input[..MAX_LEN].to_string();
    truncated.push_str("...");
    truncated
}
