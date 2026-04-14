use opencode_bridge::{
    OpenCodeBridgeError, OpenCodeClient, OpenCodeRequestContext, OpenCodeServerConfig,
    OpenCodeSessionCreateRequest, OpenCodeSessionListQuery, OpenCodeSessionUpdateRequest,
};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let server = OpenCodeServerConfig::new(
        "local-opencode",
        "Local OpenCode",
        "http://127.0.0.1:4187",
        "127.0.0.1",
        4187,
        false,
    )?;
    let client = OpenCodeClient::new(server)?;
    let context = OpenCodeRequestContext::new("/Users/franklin/Development/OpenSource/litter")?;

    let health = client.get_health().await?;
    println!(
        "health: healthy={} version={}",
        health.healthy, health.version
    );

    let project = client.get_current_project(&context).await?;
    println!(
        "project: id={} worktree={} name={}",
        project.id,
        project.worktree,
        project.name.as_deref().unwrap_or("<none>")
    );

    let path = client.get_path_info(&context).await?;
    println!(
        "path: directory={} worktree={}",
        path.directory, path.worktree
    );

    let providers = client.list_providers(&context).await?;
    println!(
        "providers: total={} connected={}",
        providers.all.len(),
        providers.connected.len()
    );

    let auth_methods = client.list_provider_auth_methods(&context).await?;
    println!("provider auth entries={}", auth_methods.len());

    let before = client
        .list_sessions(&OpenCodeSessionListQuery {
            context: context.clone(),
            roots: Some(true),
            start: None,
            search: None,
            limit: Some(20),
        })
        .await?;
    println!("sessions before create={}", before.len());

    let created = client
        .create_session(&OpenCodeSessionCreateRequest {
            context: context.clone(),
            parent_id: None,
            title: Some("Phase 2 smoke session".to_string()),
            workspace_id: None,
        })
        .await?;
    println!(
        "created session id={} title={} directory={}",
        created.id, created.title, created.directory
    );

    let fetched = client.get_session(&created.id, &context).await?;
    println!("fetched session id={} title={}", fetched.id, fetched.title);

    let messages = client
        .list_messages(&created.id, &context, Some(20), None)
        .await?;
    println!(
        "messages for created session={} next_cursor={}",
        messages.items.len(),
        messages.next_cursor.as_deref().unwrap_or("<none>")
    );

    let renamed = client
        .rename_session(
            &created.id,
            &context,
            &OpenCodeSessionUpdateRequest {
                title: Some("Phase 2 smoke session renamed".to_string()),
            },
        )
        .await?;
    println!("renamed session title={}", renamed.title);

    let aborted = client.abort_session(&created.id, &context).await?;
    println!("abort result={aborted}");

    let after = client
        .list_sessions(&OpenCodeSessionListQuery {
            context: context.clone(),
            roots: Some(true),
            start: None,
            search: Some("Phase 2 smoke".to_string()),
            limit: Some(20),
        })
        .await?;
    println!("sessions after create matching search={}", after.len());

    let mut missing_id = created.id.clone();
    let replacement = if missing_id.ends_with('A') { 'B' } else { 'A' };
    missing_id.pop();
    missing_id.push(replacement);

    match client.get_session(&missing_id, &context).await {
        Err(OpenCodeBridgeError::HttpStatus {
            endpoint,
            status,
            retryable,
            message,
            ..
        }) => {
            println!(
                "missing session normalized: endpoint={} status={} retryable={} message={}",
                endpoint, status, retryable, message
            );
        }
        Ok(_) => return Err("expected missing session request to fail".into()),
        Err(other) => {
            return Err(format!("unexpected error shape for missing session: {other:?}").into());
        }
    }

    Ok(())
}
