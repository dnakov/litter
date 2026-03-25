package com.litter.android.ui.settings

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.state.SavedServerStore
import com.litter.android.state.connectionModeLabel
import com.litter.android.state.isConnected
import com.litter.android.state.isIpcConnected
import com.litter.android.state.statusColor
import com.litter.android.state.statusLabel
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.LitterColorThemeType
import com.litter.android.ui.BerkeleyMono
import com.litter.android.ui.WallpaperBackdrop
import com.litter.android.ui.WallpaperManager
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LitterThemeIndexEntry
import com.litter.android.ui.LitterThemeManager
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.Account
import uniffi.codex_mobile_client.ExperimentalFeature
import uniffi.codex_mobile_client.ExperimentalFeatureListParams
import uniffi.codex_mobile_client.LoginAccountParams
import uniffi.codex_mobile_client.LoginAccountResponse

/**
 * Settings — hierarchical navigation matching iOS:
 * Top level: Appearance → | Font | Conversation | Experimental → | Account | Servers
 * Appearance pushes to sub-screen with theme pickers.
 * Experimental pushes to sub-screen with feature toggles.
 */

// ═══════════════════════════════════════════════════════════════════════════════
// Top-level Settings
// ═══════════════════════════════════════════════════════════════════════════════

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsSheet(
    onDismiss: () -> Unit,
    onOpenAccount: (serverId: String) -> Unit,
) {
    // Sub-screen navigation
    var subScreen by remember { mutableStateOf<SettingsSubScreen?>(null) }

    when (subScreen) {
        SettingsSubScreen.Appearance -> AppearanceScreen(onBack = { subScreen = null })
        SettingsSubScreen.Experimental -> ExperimentalScreen(onBack = { subScreen = null })
        null -> SettingsTopLevel(
            onDismiss = onDismiss,
            onOpenAppearance = { subScreen = SettingsSubScreen.Appearance },
            onOpenExperimental = { subScreen = SettingsSubScreen.Experimental },
        )
    }
}

private enum class SettingsSubScreen { Appearance, Experimental }

@Composable
private fun SettingsTopLevel(
    onDismiss: () -> Unit,
    onOpenAppearance: () -> Unit,
    onOpenExperimental: () -> Unit,
) {
    val appModel = LocalAppModel.current
    val context = LocalContext.current
    val snapshot by appModel.snapshot.collectAsState()
    val scope = rememberCoroutineScope()
    var collapseTurns by remember { mutableStateOf(false) }

    val currentServer = remember(snapshot) {
        val activeServerId = snapshot?.activeThread?.serverId
        snapshot?.servers?.firstOrNull { it.serverId == activeServerId }
            ?: snapshot?.servers?.firstOrNull { it.isLocal }
            ?: snapshot?.servers?.firstOrNull()
    }

    LazyColumn(
        modifier = Modifier
            .fillMaxWidth()
            .imePadding()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        // Title
        item {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Spacer(Modifier.weight(1f))
                Text("Settings", color = LitterTheme.textPrimary, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.weight(1f))
                TextButton(onClick = onDismiss) { Text("Done", color = LitterTheme.accent) }
            }
            Spacer(Modifier.height(8.dp))
        }

        // ── Theme ──
        item { SectionHeader("Theme") }
        item {
            NavRow(icon = Icons.Default.Palette, label = "Appearance", onClick = onOpenAppearance)
        }

        // ── Font ──
        item { SectionHeader("Font") }
        item {
            Column(
                Modifier.fillMaxWidth().background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(10.dp)),
            ) {
                FontRow("Berkeley Mono", BerkeleyMono, LitterThemeManager.monoFontEnabled) { LitterThemeManager.applyFont(true) }
                HorizontalDivider(color = LitterTheme.divider)
                FontRow("System Default", FontFamily.Default, !LitterThemeManager.monoFontEnabled) { LitterThemeManager.applyFont(false) }
            }
        }

        // ── Conversation ──
        item { SectionHeader("Conversation") }
        item {
            SettingsRow(
                icon = { Text("⊟", color = LitterTheme.accent, fontSize = 16.sp) },
                label = "Collapse Turns", subtitle = "Collapse previous turns into cards",
                trailing = { Switch(checked = collapseTurns, onCheckedChange = { collapseTurns = it }, colors = SwitchDefaults.colors(checkedTrackColor = LitterTheme.accent)) },
            )
        }

        // ── Experimental ──
        item { SectionHeader("Experimental") }
        item {
            NavRow(icon = Icons.Default.Science, label = "Experimental Features", onClick = onOpenExperimental)
        }

        // ── Account ──
        item { SectionHeader("Account") }
        item {
            if (currentServer != null) AccountSection(server = currentServer!!)
            else SettingsRow(label = "Connect to a server first")
        }

        // ── Servers ──
        item { SectionHeader("Servers") }
        val servers = snapshot?.servers ?: emptyList()
        if (servers.isEmpty()) {
            item { SettingsRow(label = "No servers connected") }
        } else {
            items(servers, key = { it.serverId }) { server ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth()
                        .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(10.dp))
                        .padding(12.dp),
                ) {
                    Text(if (server.isLocal) "📱" else "🖥", fontSize = 16.sp)
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(server.displayName, color = LitterTheme.textPrimary, fontSize = 13.sp)
                        Text(
                            "${server.statusLabel} · ${server.connectionModeLabel}",
                            color = server.statusColor,
                            fontSize = 11.sp,
                        )
                    }
                    if (server.isIpcConnected) {
                        Text(
                            "IPC",
                            color = LitterTheme.accentStrong,
                            fontSize = 10.sp,
                            modifier = Modifier
                                .background(
                                    LitterTheme.accentStrong.copy(alpha = 0.14f),
                                    RoundedCornerShape(4.dp),
                                )
                                .padding(horizontal = 6.dp, vertical = 2.dp),
                        )
                        Spacer(Modifier.width(8.dp))
                    }
                    TextButton(onClick = {
                        scope.launch {
                            SavedServerStore.remove(context, server.serverId)
                            appModel.serverBridge.disconnectServer(server.serverId)
                            appModel.refreshSnapshot()
                        }
                    }) { Text("Remove", color = LitterTheme.danger, fontSize = 12.sp) }
                }
            }
        }

        item { Spacer(Modifier.height(32.dp)) }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Appearance Sub-Screen (matches iOS AppearanceSettingsView)
// ═══════════════════════════════════════════════════════════════════════════════

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AppearanceScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var textSizeStep by remember { mutableFloatStateOf(com.litter.android.ui.TextSizePrefs.currentStep.toFloat()) }
    var showThemePicker by remember { mutableStateOf<LitterColorThemeType?>(null) }
    var wallpaperError by remember { mutableStateOf<String?>(null) }
    val wallpaperPicker =
        rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
            if (uri == null) {
                return@rememberLauncherForActivityResult
            }
            scope.launch {
                wallpaperError =
                    if (WallpaperManager.setCustomFromUri(uri)) {
                        null
                    } else {
                        "Unable to save wallpaper from the selected image."
                    }
            }
        }

    Column(
        Modifier
            .fillMaxSize()
            .imePadding()
            .padding(16.dp),
    ) {
        // Nav bar
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = LitterTheme.accent)
            }
            Spacer(Modifier.weight(1f))
            Text("Appearance", color = LitterTheme.textPrimary, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.width(48.dp))
        }

        Spacer(Modifier.height(16.dp))

        LazyColumn(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            // Font size slider
            item { SectionHeader("Font Size") }
            item {
                Column(
                    Modifier.fillMaxWidth()
                        .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(10.dp))
                        .padding(12.dp),
                ) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text("Font Size", color = LitterTheme.textPrimary, fontSize = 14.sp)
                        Spacer(Modifier.weight(1f))
                        val label = com.litter.android.ui.ConversationTextSize.fromStep(textSizeStep.toInt()).label
                        Text(label, color = LitterTheme.textSecondary, fontSize = 13.sp)
                    }
                    Spacer(Modifier.height(8.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("A", color = LitterTheme.textMuted, fontSize = 11.sp)
                        Slider(
                            value = textSizeStep,
                            onValueChange = {
                                textSizeStep = it
                                com.litter.android.ui.TextSizePrefs.setStep(context, it.toInt())
                            },
                            valueRange = 0f..6f, steps = 5,
                            modifier = Modifier.weight(1f).padding(horizontal = 8.dp),
                            colors = SliderDefaults.colors(thumbColor = LitterTheme.accent, activeTrackColor = LitterTheme.accent),
                        )
                        Text("A", color = LitterTheme.textMuted, fontSize = 18.sp)
                    }
                }
            }
            item {
                Text("Pinch in conversations to adjust, or use this slider.", color = LitterTheme.textMuted, fontSize = 11.sp, modifier = Modifier.padding(start = 4.dp))
            }

            // Wallpaper picker
            item { SectionHeader("Chat Wallpaper") }
            item {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(10.dp))
                        .padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .size(width = 48.dp, height = 72.dp)
                            .clip(RoundedCornerShape(8.dp))
                            .border(1.dp, LitterTheme.border.copy(alpha = 0.5f), RoundedCornerShape(8.dp)),
                    ) {
                        WallpaperBackdrop(Modifier.fillMaxSize())
                    }
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        TextButton(
                            onClick = { wallpaperPicker.launch("image/*") },
                            contentPadding = ButtonDefaults.TextButtonContentPadding,
                        ) {
                            Text("Choose from Library", color = LitterTheme.accent)
                        }
                        if (WallpaperManager.isWallpaperSet) {
                            TextButton(
                                onClick = {
                                    WallpaperManager.clear()
                                    wallpaperError = null
                                },
                                contentPadding = ButtonDefaults.TextButtonContentPadding,
                            ) {
                                Text("Remove Wallpaper", color = LitterTheme.danger)
                            }
                        }
                        if (!wallpaperError.isNullOrBlank()) {
                            Text(
                                wallpaperError!!,
                                color = LitterTheme.danger,
                                fontSize = 11.sp,
                            )
                        }
                    }
                }
            }

            // Conversation preview
            item { SectionHeader("Preview") }
            item {
                val scale = com.litter.android.ui.ConversationTextSize.fromStep(textSizeStep.toInt()).scale
                val previewFontSize = (14f * scale).sp
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                ) {
                    WallpaperBackdrop(Modifier.fillMaxSize())
                    Column(
                        Modifier
                            .fillMaxWidth()
                            .padding(12.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        // User bubble
                        Text(
                            "Hey, why is prod on fire",
                            color = LitterTheme.textPrimary,
                            fontSize = previewFontSize,
                            modifier = Modifier
                                .fillMaxWidth()
                                .background(LitterTheme.surface.copy(alpha = 0.5f), RoundedCornerShape(12.dp))
                                .padding(10.dp),
                        )
                        // Tool call card
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .background(LitterTheme.surface, RoundedCornerShape(8.dp))
                                .padding(8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text("✓", color = LitterTheme.success, fontSize = 12.sp)
                            Spacer(Modifier.width(6.dp))
                            Text("rg 'TODO: fix later' --count", color = LitterTheme.toolCallCommand, fontFamily = BerkeleyMono, fontSize = (previewFontSize.value - 2).sp)
                            Spacer(Modifier.weight(1f))
                            Text("0.3s", color = LitterTheme.textMuted, fontSize = 10.sp)
                        }
                        // Assistant bubble
                        Text(
                            "Found the issue. Someone deployed this:\n\n```python\nif is_friday():\n    yolo_deploy(skip_tests=True)\n```\n\nI'm not mad, just disappointed.",
                            color = LitterTheme.textBody,
                            fontSize = previewFontSize,
                        )
                        // User reply
                        Text(
                            "That was you",
                            color = LitterTheme.textPrimary,
                            fontSize = previewFontSize,
                            modifier = Modifier
                                .fillMaxWidth()
                                .background(LitterTheme.surface.copy(alpha = 0.5f), RoundedCornerShape(12.dp))
                                .padding(10.dp),
                        )
                    }
                }
            }

            // Light theme picker
            item { SectionHeader("Light Theme") }
            item {
                val selectedLight = LitterThemeManager.lightThemes.firstOrNull {
                    it.slug == LitterThemeManager.lightTheme.slug
                } ?: LitterThemeManager.lightThemes.firstOrNull()
                ThemePickerButton(entry = selectedLight, onClick = { showThemePicker = LitterColorThemeType.LIGHT })
            }

            // Dark theme picker
            item { SectionHeader("Dark Theme") }
            item {
                val selectedDark = LitterThemeManager.darkThemes.firstOrNull {
                    it.slug == LitterThemeManager.darkTheme.slug
                } ?: LitterThemeManager.darkThemes.firstOrNull()
                ThemePickerButton(entry = selectedDark, onClick = { showThemePicker = LitterColorThemeType.DARK })
            }
        }
    }

    // Theme picker sheet
    showThemePicker?.let { type ->
        ModalBottomSheet(
            onDismissRequest = { showThemePicker = null },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            containerColor = LitterTheme.background,
        ) {
            val themes = if (type == LitterColorThemeType.DARK) LitterThemeManager.darkThemes else LitterThemeManager.lightThemes
            val selectedSlug = if (type == LitterColorThemeType.DARK) LitterThemeManager.darkTheme.slug else LitterThemeManager.lightTheme.slug
            ThemePickerContent(
                title = if (type == LitterColorThemeType.DARK) "Dark Theme" else "Light Theme",
                themes = themes,
                selectedSlug = selectedSlug,
                onSelect = { slug ->
                    if (type == LitterColorThemeType.DARK) {
                        LitterThemeManager.selectDarkTheme(slug)
                        LitterThemeManager.applyDarkMode(true)
                    } else {
                        LitterThemeManager.selectLightTheme(slug)
                        LitterThemeManager.applyDarkMode(false)
                    }
                    showThemePicker = null
                },
                onDismiss = { showThemePicker = null },
            )
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Theme Picker Sheet (matches iOS ThemePickerSheet)
// ═══════════════════════════════════════════════════════════════════════════════

@Composable
private fun ThemePickerContent(
    title: String,
    themes: List<LitterThemeIndexEntry>,
    selectedSlug: String,
    onSelect: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var searchQuery by remember { mutableStateOf("") }
    val filtered = remember(themes, searchQuery) {
        if (searchQuery.isBlank()) themes
        else themes.filter { it.name.contains(searchQuery, ignoreCase = true) || it.slug.contains(searchQuery, ignoreCase = true) }
    }

    Column(
        Modifier
            .fillMaxWidth()
            .imePadding()
            .padding(16.dp),
    ) {
        // Title + Done
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Spacer(Modifier.weight(1f))
            Text(title, color = LitterTheme.textPrimary, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onDismiss) { Text("Done", color = LitterTheme.accent) }
        }

        Spacer(Modifier.height(8.dp))

        // Search
        Row(
            Modifier.fillMaxWidth()
                .background(LitterTheme.surface.copy(alpha = 0.55f), RoundedCornerShape(10.dp))
                .border(1.dp, LitterTheme.border.copy(alpha = 0.85f), RoundedCornerShape(10.dp))
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Default.Search, null, tint = LitterTheme.textMuted, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(8.dp))
            BasicTextField(
                value = searchQuery, onValueChange = { searchQuery = it },
                textStyle = TextStyle(color = LitterTheme.textPrimary, fontSize = 14.sp),
                cursorBrush = SolidColor(LitterTheme.accent),
                modifier = Modifier.fillMaxWidth(),
                decorationBox = { inner ->
                    if (searchQuery.isEmpty()) Text("Search themes", color = LitterTheme.textMuted, fontSize = 14.sp)
                    inner()
                },
            )
        }

        Spacer(Modifier.height(12.dp))

        // Theme list
        if (filtered.isEmpty()) {
            Column(Modifier.fillMaxWidth().padding(top = 48.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(Icons.Default.Search, null, tint = LitterTheme.textMuted, modifier = Modifier.size(24.dp))
                Spacer(Modifier.height(8.dp))
                Text("No matching themes", color = LitterTheme.textPrimary, fontSize = 14.sp)
            }
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(filtered, key = { it.slug }) { entry ->
                    val isSelected = entry.slug == selectedSlug
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth()
                            .background(LitterTheme.surface.copy(alpha = 0.72f), RoundedCornerShape(12.dp))
                            .border(
                                1.dp,
                                if (isSelected) LitterTheme.accent.copy(alpha = 0.6f) else LitterTheme.border.copy(alpha = 0.85f),
                                RoundedCornerShape(12.dp),
                            )
                            .clickable { onSelect(entry.slug) }
                            .padding(horizontal = 12.dp, vertical = 11.dp),
                    ) {
                        ThemePreviewBadge(entry)
                        Spacer(Modifier.width(10.dp))
                        Text(entry.name, color = LitterTheme.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
                        if (isSelected) {
                            Icon(Icons.Default.Check, null, tint = LitterTheme.accent, modifier = Modifier.size(16.dp))
                        }
                    }
                }
            }
        }
    }
}

/** "Aa" badge with background/foreground/accent dot — matches iOS ThemePreviewBadge */
@Composable
private fun ThemePreviewBadge(entry: LitterThemeIndexEntry) {
    val bg = try { Color(android.graphics.Color.parseColor(entry.backgroundHex)) } catch (_: Exception) { LitterTheme.surface }
    val fg = try { Color(android.graphics.Color.parseColor(entry.foregroundHex)) } catch (_: Exception) { LitterTheme.textPrimary }
    val accent = try { Color(android.graphics.Color.parseColor(entry.accentHex)) } catch (_: Exception) { LitterTheme.accent }

    Box {
        Box(
            Modifier.size(width = 28.dp, height = 22.dp)
                .background(bg, RoundedCornerShape(5.dp))
                .border(0.5.dp, Color.Gray.copy(alpha = 0.3f), RoundedCornerShape(5.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Text("Aa", color = fg, fontSize = 11.sp, fontWeight = FontWeight.Bold, fontFamily = BerkeleyMono)
        }
        Spacer(
            Modifier.size(6.dp).clip(CircleShape).background(accent)
                .align(Alignment.BottomEnd),
        )
    }
}

@Composable
private fun ThemePickerButton(entry: LitterThemeIndexEntry?, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth()
            .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(10.dp))
            .clickable(onClick = onClick)
            .padding(12.dp),
    ) {
        if (entry != null) {
            ThemePreviewBadge(entry)
            Spacer(Modifier.width(10.dp))
            Text(entry.name, color = LitterTheme.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
        } else {
            Text("No themes", color = LitterTheme.textMuted, fontSize = 14.sp, modifier = Modifier.weight(1f))
        }
        Text("⇅", color = LitterTheme.textMuted, fontSize = 12.sp)
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Experimental Sub-Screen (matches iOS ExperimentalFeaturesView)
// ═══════════════════════════════════════════════════════════════════════════════

@Composable
private fun ExperimentalScreen(onBack: () -> Unit) {
    val appModel = LocalAppModel.current
    val snapshot by appModel.snapshot.collectAsState()
    var features by remember { mutableStateOf<List<ExperimentalFeature>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }

    val serverId = remember(snapshot) { snapshot?.servers?.firstOrNull { it.isConnected }?.serverId }

    LaunchedEffect(serverId) {
        if (serverId != null) {
            try {
                val resp = appModel.rpc.experimentalFeatureList(serverId, ExperimentalFeatureListParams(cursor = null, limit = null))
                features = resp.data
            } catch (_: Exception) {}
        }
        isLoading = false
    }

    Column(
        Modifier
            .fillMaxSize()
            .imePadding()
            .padding(16.dp),
    ) {
        // Nav bar
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = LitterTheme.accent)
            }
            Spacer(Modifier.weight(1f))
            Text("Experimental", color = LitterTheme.textPrimary, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.width(48.dp))
        }

        Spacer(Modifier.height(16.dp))

        SectionHeader("Features")

        if (isLoading) {
            Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp, color = LitterTheme.accent)
            }
        } else if (features.isEmpty()) {
            Text("No experimental features available.", color = LitterTheme.textMuted, fontSize = 13.sp, modifier = Modifier.padding(12.dp))
        } else {
            Column(
                Modifier.fillMaxWidth().background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(10.dp)),
            ) {
                features.forEachIndexed { idx, feature ->
                    var enabled by remember { mutableStateOf(false) }
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(feature.displayName ?: feature.name, color = LitterTheme.textPrimary, fontSize = 14.sp)
                            feature.description?.let { Text(it, color = LitterTheme.textSecondary, fontSize = 11.sp) }
                        }
                        Switch(checked = enabled, onCheckedChange = { enabled = it }, colors = SwitchDefaults.colors(checkedTrackColor = LitterTheme.accent))
                    }
                    if (idx < features.lastIndex) HorizontalDivider(color = LitterTheme.divider)
                }
            }
            Spacer(Modifier.height(8.dp))
            Text("Experimental features may be unstable or change without notice.", color = LitterTheme.textMuted, fontSize = 11.sp, modifier = Modifier.padding(start = 4.dp))
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Account Section (inline in top-level, matches iOS SettingsConnectionAccountSection)
// ═══════════════════════════════════════════════════════════════════════════════

@Composable
private fun AccountSection(server: uniffi.codex_mobile_client.AppServerSnapshot) {
    val appModel = LocalAppModel.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var apiKey by remember { mutableStateOf("") }
    var isAuthWorking by remember { mutableStateOf(false) }
    var authError by remember { mutableStateOf<String?>(null) }

    val authColor = when (server.account) {
        is Account.Chatgpt -> LitterTheme.accent
        is Account.ApiKey -> Color(0xFF00AAFF)
        else -> LitterTheme.textMuted
    }
    val authTitle = when (val acct = server.account) {
        is Account.Chatgpt -> acct.email.ifEmpty { "ChatGPT" }
        is Account.ApiKey -> "API Key"
        else -> "Not logged in"
    }
    val authSubtitle = when (server.account) {
        is Account.Chatgpt -> "ChatGPT account"
        is Account.ApiKey -> "OpenAI API key"
        else -> null
    }

    Column(
        Modifier.fillMaxWidth().background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(10.dp)).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Status row
        Row(verticalAlignment = Alignment.CenterVertically) {
            Spacer(Modifier.size(10.dp).clip(CircleShape).background(authColor))
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(authTitle, color = LitterTheme.textPrimary, fontSize = 14.sp)
                authSubtitle?.let { Text(it, color = LitterTheme.textSecondary, fontSize = 11.sp) }
            }
            if (server.isLocal && server.account != null) {
                TextButton(onClick = {
                    scope.launch {
                        try { appModel.rpc.logoutAccount(server.serverId); appModel.refreshSnapshot() } catch (_: Exception) {}
                    }
                }) { Text("Logout", color = LitterTheme.danger, fontSize = 12.sp) }
            }
        }

        // Login button
        if (server.isLocal && server.account == null) {
            Button(
                onClick = {
                    scope.launch {
                        isAuthWorking = true
                        try {
                            val resp = appModel.rpc.loginAccount(server.serverId, LoginAccountParams.Chatgpt)
                            if (resp is LoginAccountResponse.Chatgpt) {
                                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(resp.authUrl)))
                            }
                        } catch (e: Exception) { authError = e.message }
                        isAuthWorking = false
                    }
                },
                enabled = !isAuthWorking,
                colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent),
            ) {
                if (isAuthWorking) { CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = LitterTheme.textPrimary); Spacer(Modifier.width(6.dp)) }
                Text("Login with ChatGPT", color = LitterTheme.accent, fontSize = 14.sp)
            }
        }

        if (server.isLocal) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                BasicTextField(
                    value = apiKey, onValueChange = { apiKey = it },
                    textStyle = TextStyle(color = LitterTheme.textPrimary, fontSize = 13.sp),
                    cursorBrush = SolidColor(LitterTheme.accent),
                    visualTransformation = PasswordVisualTransformation(),
                    modifier = Modifier.weight(1f).background(LitterTheme.codeBackground, RoundedCornerShape(6.dp)).padding(8.dp),
                    decorationBox = { inner -> if (apiKey.isEmpty()) Text("sk-...", color = LitterTheme.textMuted, fontSize = 13.sp); inner() },
                )
                Spacer(Modifier.width(8.dp))
                TextButton(
                    onClick = {
                        val key = apiKey.trim(); if (key.isEmpty()) return@TextButton
                        scope.launch {
                            isAuthWorking = true
                            try { appModel.rpc.loginAccount(server.serverId, LoginAccountParams.ApiKey(apiKey = key)); appModel.refreshSnapshot(); apiKey = ""; authError = null } catch (e: Exception) { authError = e.message }
                            isAuthWorking = false
                        }
                    },
                    enabled = apiKey.trim().isNotEmpty() && !isAuthWorking,
                ) { Text("Save", color = LitterTheme.accent, fontSize = 12.sp) }
            }
        } else {
            Text(
                "Remote servers request their own OAuth login when needed. Settings login and API key entry stay local-only.",
                color = LitterTheme.textSecondary,
                fontSize = 11.sp,
            )
        }

        authError?.let { Text(it, color = LitterTheme.danger, fontSize = 11.sp) }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Shared Components
// ═══════════════════════════════════════════════════════════════════════════════

@Composable
private fun SectionHeader(text: String) {
    Spacer(Modifier.height(8.dp))
    Text(text.uppercase(), color = LitterTheme.textSecondary, fontSize = 11.sp, fontWeight = FontWeight.Medium, modifier = Modifier.padding(start = 4.dp, bottom = 4.dp))
}

@Composable
private fun SettingsRow(
    label: String, subtitle: String? = null,
    icon: (@Composable () -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
    onClick: (() -> Unit)? = null,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth()
            .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(10.dp))
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(12.dp),
    ) {
        icon?.invoke()
        if (icon != null) Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(label, color = LitterTheme.textPrimary, fontSize = 14.sp)
            subtitle?.let { Text(it, color = LitterTheme.textSecondary, fontSize = 11.sp) }
        }
        trailing?.invoke()
    }
}

@Composable
private fun NavRow(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    SettingsRow(
        icon = { Icon(icon, null, tint = LitterTheme.accent, modifier = Modifier.size(20.dp)) },
        label = label,
        trailing = { Icon(Icons.Default.ChevronRight, null, tint = LitterTheme.textMuted, modifier = Modifier.size(16.dp)) },
        onClick = onClick,
    )
}

@Composable
private fun FontRow(name: String, fontFamily: FontFamily, isSelected: Boolean, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(12.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(name, color = LitterTheme.textPrimary, fontSize = 14.sp)
            Text("The quick brown fox", color = LitterTheme.textSecondary, fontSize = 13.sp, fontFamily = fontFamily)
        }
        if (isSelected) Icon(Icons.Default.Check, null, tint = LitterTheme.accent, modifier = Modifier.size(18.dp))
    }
}
