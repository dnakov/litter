package com.litter.android.ui.apps

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.litter.android.state.SavedAppsStore
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.home.SwipeToHideRow
import com.litter.android.ui.scaled
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.SavedApp
import java.util.concurrent.TimeUnit

@Composable
fun AppsListScreen(
    onBack: () -> Unit,
    onOpenApp: (String) -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val apps by SavedAppsStore.apps.collectAsState()

    LaunchedEffect(Unit) {
        SavedAppsStore.reload(context)
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(LitterTheme.background)
            .systemBarsPadding(),
    ) {
        // Top bar
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onBack) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    tint = LitterTheme.textPrimary,
                )
            }
            Text(
                text = "Apps",
                color = LitterTheme.textPrimary,
                fontSize = LitterTextStyle.headline.scaled,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(start = 4.dp),
            )
        }

        if (apps.isEmpty()) {
            EmptyState()
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(
                    horizontal = 12.dp,
                    vertical = 8.dp,
                ),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                items(apps, key = { it.id }) { app ->
                    SwipeToHideRow(
                        onHide = {
                            scope.launch {
                                try {
                                    SavedAppsStore.delete(context, app.id)
                                } catch (_: Exception) {}
                            }
                        },
                    ) {
                        AppRow(app = app, onClick = { onOpenApp(app.id) })
                    }
                }
            }
        }
    }
}

@Composable
private fun AppRow(
    app: SavedApp,
    onClick: () -> Unit,
) {
    val monogram = app.title.trim().firstOrNull()?.uppercaseChar()?.toString() ?: "?"

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(12.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(LitterTheme.accent.copy(alpha = 0.18f)),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = monogram,
                color = LitterTheme.accent,
                fontSize = LitterTextStyle.headline.scaled,
                fontWeight = FontWeight.SemiBold,
            )
        }
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = app.title.ifBlank { "Untitled App" },
                color = LitterTheme.textPrimary,
                fontSize = LitterTextStyle.callout.scaled,
                fontWeight = FontWeight.Medium,
            )
            Text(
                text = relativeTime(app.updatedAtMs),
                color = LitterTheme.textMuted,
                fontSize = LitterTextStyle.caption2.scaled,
            )
        }
    }
}

@Composable
private fun EmptyState() {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = "No saved apps yet",
                color = LitterTheme.textPrimary,
                fontSize = LitterTextStyle.headline.scaled,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "When the AI generates an interactive widget with an app_id in a local-server conversation, it saves here automatically. State persists across updates.",
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.footnote.scaled,
            )
        }
    }
}

private fun relativeTime(millis: Long): String {
    val delta = System.currentTimeMillis() - millis
    if (delta < 0) return "just now"
    val seconds = TimeUnit.MILLISECONDS.toSeconds(delta)
    val minutes = TimeUnit.MILLISECONDS.toMinutes(delta)
    val hours = TimeUnit.MILLISECONDS.toHours(delta)
    val days = TimeUnit.MILLISECONDS.toDays(delta)
    return when {
        seconds < 60 -> "just now"
        minutes < 60 -> "${minutes}m ago"
        hours < 24 -> "${hours}h ago"
        days < 7 -> "${days}d ago"
        else -> "${days / 7}w ago"
    }
}
