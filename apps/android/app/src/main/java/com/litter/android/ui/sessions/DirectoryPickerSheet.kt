package com.litter.android.ui.sessions

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.KeyboardArrowLeft
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.state.AppLifecycleController
import com.litter.android.state.SavedServerStore
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.RecentDirectoryEntry
import com.litter.android.ui.RecentDirectoryStore
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.AppServerBackendKind
import uniffi.codex_mobile_client.RemotePath

@Composable
fun DirectoryPickerSheet(
    server: ServerPickerOption,
    onSelect: (cwd: String) -> Unit,
    onBack: () -> Unit,
    onDismiss: () -> Unit,
) {
    val appModel = LocalAppModel.current
    val context = LocalContext.current
    val recentStore = remember(context) { RecentDirectoryStore(context) }
    val lifecycleController = remember { AppLifecycleController() }
    val scope = rememberCoroutineScope()

    var currentPath by remember(server.id) { mutableStateOf(server.lastUsedDirectoryHint ?: "") }
    var allEntries by remember(server.id) { mutableStateOf<List<String>>(emptyList()) }
    var recentEntries by remember(server.id) { mutableStateOf<List<RecentDirectoryEntry>>(emptyList()) }
    var knownDirectories by remember(server.id, server.knownDirectories) {
        mutableStateOf(loadKnownDirectories(context, server))
    }
    var isLoading by remember(server.id) { mutableStateOf(server.canBrowseDirectories) }
    var errorMessage by remember(server.id) { mutableStateOf<String?>(null) }
    var showHiddenDirectories by remember { mutableStateOf(false) }
    var searchQuery by remember(server.id) { mutableStateOf("") }
    var addDirectoryText by remember(server.id) { mutableStateOf("") }
    var editTarget by remember(server.id) { mutableStateOf<String?>(null) }
    var editDirectoryText by remember(server.id) { mutableStateOf("") }

    fun refreshRecentEntries() {
        recentEntries = recentStore.listForServer(server.id, limit = 8)
    }

    fun completeSelection(path: String) {
        recentEntries = recentStore.record(server.id, path, limit = 8)
        onSelect(path)
    }

    fun relativeTime(epochMillis: Long): String {
        val deltaMinutes = ((System.currentTimeMillis() - epochMillis).coerceAtLeast(0L) / 60000L)
        return when {
            deltaMinutes < 1L -> "just now"
            deltaMinutes < 60L -> "${deltaMinutes}m ago"
            deltaMinutes < 1440L -> "${deltaMinutes / 60L}h ago"
            deltaMinutes < 10080L -> "${deltaMinutes / 1440L}d ago"
            else -> "${deltaMinutes / 10080L}w ago"
        }
    }

    fun isDisconnectedError(error: Throwable): Boolean {
        val message = error.message?.lowercase().orEmpty()
        return "disconnected" in message ||
            ("transport error" in message && "not connected" in message)
    }

    suspend fun listDirectory(path: String) {
        if (!server.canBrowseDirectories) {
            isLoading = false
            return
        }
        val normalizedPath = path.trim().ifEmpty { "/" }
        isLoading = true
        errorMessage = null
        val response = runCatching { appModel.client.listRemoteDirectory(server.id, normalizedPath) }
        response.onSuccess { result ->
            allEntries = result.directories
            currentPath = result.path
        }.onFailure { error ->
            allEntries = emptyList()
            errorMessage = if (isDisconnectedError(error)) {
                "Selected server is not connected."
            } else {
                error.message ?: "Failed to list directory."
            }
        }
        isLoading = false
    }

    suspend fun loadInitialPath() {
        if (!server.canBrowseDirectories) {
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = null
        allEntries = emptyList()
        val home = runCatching { appModel.client.resolveRemoteHome(server.id) }
            .getOrElse { error ->
                if (isDisconnectedError(error)) {
                    errorMessage = "Selected server is not connected."
                }
                "/"
            }
        currentPath = home
        listDirectory(home)
    }

    suspend fun reconnectOpenCodeScopes() {
        lifecycleController.reconnectServer(context, appModel, server.id)
        knownDirectories = loadKnownDirectories(context, server)
    }

    fun pathSegments(path: String): List<Pair<String, String>> {
        val normalized = path.trim()
        if (normalized.isEmpty()) return listOf("/" to "/")
        return RemotePath.parse(normalized).segments().map { seg ->
            seg.label to seg.fullPath
        }
    }

    val filteredEntries = remember(allEntries, searchQuery, showHiddenDirectories) {
        val hiddenFiltered = if (showHiddenDirectories) allEntries else allEntries.filterNot { it.startsWith(".") }
        val query = searchQuery.trim()
        if (query.isEmpty()) hiddenFiltered else hiddenFiltered.filter { it.contains(query, ignoreCase = true) }
    }
    val filteredKnownDirectories = remember(knownDirectories, searchQuery) {
        val query = searchQuery.trim()
        if (query.isEmpty()) {
            knownDirectories
        } else {
            knownDirectories.filter { it.contains(query, ignoreCase = true) }
        }
    }

    LaunchedEffect(server.id) {
        searchQuery = ""
        refreshRecentEntries()
        knownDirectories = loadKnownDirectories(context, server)
        if (server.canBrowseDirectories) {
            loadInitialPath()
        } else {
            isLoading = false
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .fillMaxHeight(0.94f),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.background)
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack) {
                    Icon(
                        Icons.Default.KeyboardArrowLeft,
                        contentDescription = "Back to server picker",
                        tint = LitterTheme.textPrimary,
                    )
                }
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = if (server.backendKind == AppServerBackendKind.OPEN_CODE) {
                            "Pick Workspace"
                        } else {
                            "Pick Directory"
                        },
                        color = LitterTheme.textPrimary,
                        fontSize = 18.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = "${server.name} • ${server.subtitle}",
                        color = LitterTheme.textSecondary,
                        fontSize = 12.sp,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }

            if (server.backendKind == AppServerBackendKind.OPEN_CODE) {
                Text(
                    text = "OpenCode sessions stay bound to one saved directory scope.",
                    color = LitterTheme.textSecondary,
                    fontSize = 12.sp,
                )
            }

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(LitterTheme.surface, RoundedCornerShape(8.dp))
                    .border(1.dp, LitterTheme.border.copy(alpha = 0.85f), RoundedCornerShape(8.dp))
                    .padding(horizontal = 10.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Default.Search, contentDescription = null, tint = LitterTheme.textMuted)
                Spacer(Modifier.size(8.dp))
                Box(modifier = Modifier.weight(1f)) {
                    if (searchQuery.isEmpty()) {
                        Text(
                            if (server.backendKind == AppServerBackendKind.OPEN_CODE) {
                                "Search saved scopes"
                            } else {
                                "Search folders"
                            },
                            color = LitterTheme.textMuted,
                            fontSize = 13.sp,
                        )
                    }
                    BasicTextField(
                        value = searchQuery,
                        onValueChange = { searchQuery = it },
                        textStyle = TextStyle(color = LitterTheme.textPrimary, fontSize = 13.sp),
                        cursorBrush = SolidColor(LitterTheme.accent),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                if (server.canBrowseDirectories) {
                    IconButton(onClick = { showHiddenDirectories = !showHiddenDirectories }) {
                        Icon(
                            imageVector = if (showHiddenDirectories) Icons.Default.Visibility else Icons.Default.VisibilityOff,
                            contentDescription = if (showHiddenDirectories) "Hide hidden folders" else "Show hidden folders",
                            tint = if (showHiddenDirectories) LitterTheme.accent else LitterTheme.textSecondary,
                        )
                    }
                } else if (searchQuery.isNotEmpty()) {
                    IconButton(onClick = { searchQuery = "" }) {
                        Icon(Icons.Default.Clear, contentDescription = "Clear search", tint = LitterTheme.textMuted)
                    }
                }
            }

            if (server.canBrowseDirectories) {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    item {
                        Text(
                            text = "Up one level",
                            color = if (currentPath != "/" && currentPath.isNotEmpty()) LitterTheme.accent else LitterTheme.textMuted,
                            fontSize = 12.sp,
                            modifier = Modifier
                                .background(LitterTheme.surface, RoundedCornerShape(8.dp))
                                .clickable(enabled = currentPath != "/" && currentPath.isNotEmpty()) {
                                    scope.launch { listDirectory(RemotePath.parse(currentPath).parent().asString()) }
                                }
                                .padding(horizontal = 10.dp, vertical = 6.dp),
                        )
                    }
                    items(pathSegments(currentPath)) { segment ->
                        val isCurrent = segment.second == currentPath
                        Text(
                            text = segment.first,
                            color = if (isCurrent) Color.Black else LitterTheme.textSecondary,
                            fontSize = 12.sp,
                            modifier = Modifier
                                .background(
                                    if (isCurrent) LitterTheme.accent else LitterTheme.surface,
                                    RoundedCornerShape(8.dp),
                                )
                                .clickable { scope.launch { listDirectory(segment.second) } }
                                .padding(horizontal = 10.dp, vertical = 6.dp),
                        )
                    }
                }
            } else {
                OutlinedTextField(
                    value = addDirectoryText,
                    onValueChange = { addDirectoryText = it },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("Add directory scope") },
                    singleLine = true,
                    trailingIcon = {
                        Text(
                            text = "Save",
                            color = if (addDirectoryText.isBlank()) LitterTheme.textMuted else LitterTheme.accent,
                            modifier = Modifier.clickable(enabled = addDirectoryText.isNotBlank()) {
                                val nextDirectory = addDirectoryText.trim()
                                SavedServerStore.appendOpenCodeDirectory(context, server.id, nextDirectory)
                                addDirectoryText = ""
                                scope.launch { reconnectOpenCodeScopes() }
                            },
                        )
                    },
                )
            }
        }

        when {
            isLoading -> {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth(),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("Loading…", color = LitterTheme.textSecondary, fontSize = 13.sp)
                }
            }

            errorMessage != null -> {
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .padding(horizontal = 24.dp),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text("Unable to load workspace", color = LitterTheme.danger, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                    Spacer(Modifier.height(8.dp))
                    Text(
                        text = errorMessage ?: "",
                        color = LitterTheme.textSecondary,
                        fontSize = 12.sp,
                        maxLines = 4,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (server.canBrowseDirectories) {
                        Spacer(Modifier.height(12.dp))
                        Text(
                            text = "Retry",
                            color = LitterTheme.accent,
                            fontSize = 13.sp,
                            modifier = Modifier.clickable { scope.launch { listDirectory(currentPath.ifEmpty { "/" }) } },
                        )
                    }
                }
            }

            server.backendKind == AppServerBackendKind.OPEN_CODE -> {
                LazyColumn(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .background(LitterTheme.background),
                ) {
                    val mostRecentEntry = recentEntries.firstOrNull()
                    if (mostRecentEntry != null && searchQuery.isBlank()) {
                        item("recent-continue") {
                            PickerRow(
                                icon = Icons.Default.CheckCircle,
                                title = "Continue in ${(mostRecentEntry.path.substringAfterLast('/')).ifBlank { mostRecentEntry.path }}",
                                subtitle = mostRecentEntry.path,
                                accent = LitterTheme.accent,
                                onClick = { completeSelection(mostRecentEntry.path) },
                            )
                        }
                    }

                    item("saved-header") {
                        Text(
                            text = "Saved directory scopes",
                            color = LitterTheme.textSecondary,
                            fontSize = 12.sp,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                        )
                    }

                    if (filteredKnownDirectories.isEmpty()) {
                        item("empty-open-code") {
                            Text(
                                text = "Add at least one directory scope for this OpenCode server.",
                                color = LitterTheme.textMuted,
                                fontSize = 12.sp,
                                modifier = Modifier.padding(horizontal = 16.dp, vertical = 20.dp),
                            )
                        }
                    } else {
                        items(filteredKnownDirectories, key = { "scope-$it" }) { directory ->
                            ScopeRow(
                                title = directory.substringAfterLast('/').ifBlank { directory },
                                subtitle = directory,
                                onSelect = { completeSelection(directory) },
                                onEdit = {
                                    editTarget = directory
                                    editDirectoryText = directory
                                },
                                onRemove = {
                                    SavedServerStore.removeOpenCodeDirectory(context, server.id, directory)
                                    scope.launch { reconnectOpenCodeScopes() }
                                },
                            )
                        }
                    }
                }
            }

            else -> {
                LazyColumn(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .background(LitterTheme.background),
                ) {
                    val mostRecentEntry = recentEntries.firstOrNull()
                    if (mostRecentEntry != null && searchQuery.isBlank()) {
                        item("recent-continue") {
                            PickerRow(
                                icon = Icons.Default.CheckCircle,
                                title = "Continue in ${(mostRecentEntry.path.substringAfterLast('/')).ifBlank { mostRecentEntry.path }}",
                                subtitle = mostRecentEntry.path,
                                accent = LitterTheme.accent,
                                onClick = { completeSelection(mostRecentEntry.path) },
                            )
                        }
                    }

                    if (recentEntries.isNotEmpty() && searchQuery.isBlank()) {
                        item("recent-header") {
                            Text(
                                text = "Recent directories",
                                color = LitterTheme.textSecondary,
                                fontSize = 12.sp,
                                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                            )
                        }
                        items(recentEntries, key = { "recent-${it.serverId}-${it.path}" }) { recent ->
                            PickerRow(
                                icon = Icons.Default.Folder,
                                title = recent.path.substringAfterLast('/').ifBlank { recent.path },
                                subtitle = "${recent.path} • ${relativeTime(recent.lastUsedAtEpochMillis)}",
                                accent = LitterTheme.textSecondary,
                                onClick = { completeSelection(recent.path) },
                            )
                        }
                    }

                    if (filteredEntries.isEmpty()) {
                        item("empty") {
                            Text(
                                text = if (searchQuery.isBlank()) "No subdirectories" else "No matches for \"$searchQuery\"",
                                color = LitterTheme.textMuted,
                                fontSize = 12.sp,
                                modifier = Modifier.padding(horizontal = 16.dp, vertical = 20.dp),
                            )
                        }
                    } else {
                        items(filteredEntries, key = { "entry-$it" }) { entry ->
                            PickerRow(
                                icon = Icons.Default.Folder,
                                title = entry,
                                subtitle = null,
                                accent = LitterTheme.accent,
                                onClick = {
                                    scope.launch {
                                        listDirectory(RemotePath.parse(currentPath).join(entry).asString())
                                    }
                                },
                            )
                        }
                    }
                }
            }
        }

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.background)
                .padding(horizontal = 16.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = currentPath.ifBlank {
                    if (server.backendKind == AppServerBackendKind.OPEN_CODE) {
                        "Choose a saved directory scope to start an OpenCode session."
                    } else {
                        "Choose a folder to start a new session."
                    }
                },
                color = if (currentPath.isBlank()) LitterTheme.textSecondary else LitterTheme.textMuted,
                fontSize = 12.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Button(
                    onClick = onDismiss,
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = LitterTheme.surface,
                        contentColor = LitterTheme.textPrimary,
                    ),
                ) {
                    Text("Cancel")
                }
                Button(
                    onClick = { completeSelection(currentPath) },
                    enabled = currentPath.isNotBlank(),
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = if (currentPath.isNotBlank()) LitterTheme.accent else LitterTheme.surface,
                        contentColor = if (currentPath.isNotBlank()) Color.Black else LitterTheme.textMuted,
                    ),
                ) {
                    Text(if (server.backendKind == AppServerBackendKind.OPEN_CODE) "Start Session" else "Select Folder")
                }
            }
        }
    }

    if (editTarget != null) {
        AlertDialog(
            onDismissRequest = {
                editTarget = null
                editDirectoryText = ""
            },
            title = { Text("Edit Directory Scope") },
            text = {
                OutlinedTextField(
                    value = editDirectoryText,
                    onValueChange = { editDirectoryText = it },
                    label = { Text("Directory") },
                    singleLine = true,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    val target = editTarget ?: return@TextButton
                    SavedServerStore.replaceOpenCodeDirectory(context, server.id, target, editDirectoryText)
                    editTarget = null
                    editDirectoryText = ""
                    scope.launch { reconnectOpenCodeScopes() }
                }) {
                    Text("Save", color = LitterTheme.accent)
                }
            },
            dismissButton = {
                TextButton(onClick = {
                    editTarget = null
                    editDirectoryText = ""
                }) {
                    Text("Cancel", color = LitterTheme.textSecondary)
                }
            },
        )
    }
}

private fun loadKnownDirectories(
    context: android.content.Context,
    server: ServerPickerOption,
): List<String> = SavedServerStore.server(context, server.id)
    ?.openCodeKnownDirectories
    ?.ifEmpty { server.knownDirectories }
    ?: server.knownDirectories

@Composable
private fun PickerRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    subtitle: String?,
    accent: Color,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = accent)
        Spacer(Modifier.size(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(title, color = LitterTheme.textPrimary, fontSize = 13.sp, fontWeight = FontWeight.Medium)
            subtitle?.let {
                Spacer(Modifier.height(2.dp))
                Text(it, color = LitterTheme.textMuted, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun ScopeRow(
    title: String,
    subtitle: String,
    onSelect: () -> Unit,
    onEdit: () -> Unit,
    onRemove: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onSelect)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Default.Folder, contentDescription = null, tint = LitterTheme.accent)
        Spacer(Modifier.size(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(title, color = LitterTheme.textPrimary, fontSize = 13.sp, fontWeight = FontWeight.Medium)
            Text(subtitle, color = LitterTheme.textMuted, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        IconButton(onClick = onEdit) {
            Icon(Icons.Default.Edit, contentDescription = "Edit scope", tint = LitterTheme.textSecondary)
        }
        IconButton(onClick = onRemove) {
            Icon(Icons.Default.DeleteOutline, contentDescription = "Remove scope", tint = LitterTheme.danger)
        }
    }
}
