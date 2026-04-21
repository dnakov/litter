package com.litter.android.ui.home

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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.Divider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.state.displayTitle
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.scaled
import uniffi.codex_mobile_client.AppSessionSummary
import uniffi.codex_mobile_client.PinnedThreadKey

/**
 * List of every thread across connected servers, sorted by recency and
 * filtered by the current query. Tapping a row toggles its pinned state.
 */
@Composable
fun ThreadSearchResults(
    sessions: List<AppSessionSummary>,
    pinnedKeys: Set<PinnedThreadKey>,
    query: String,
    onPin: (AppSessionSummary) -> Unit,
    onUnpin: (AppSessionSummary) -> Unit,
    modifier: Modifier = Modifier,
) {
    val filtered = if (query.isBlank()) {
        sessions
    } else {
        val needle = query.trim().lowercase()
        sessions.filter { session ->
            session.displayTitle.lowercase().contains(needle)
                || (session.cwd ?: "").lowercase().contains(needle)
                || session.serverDisplayName.lowercase().contains(needle)
                || session.preview.lowercase().contains(needle)
        }
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(LitterTheme.surface.copy(alpha = 0.92f), RoundedCornerShape(14.dp))
            .border(1.dp, LitterTheme.border.copy(alpha = 0.5f), RoundedCornerShape(14.dp)),
    ) {
        if (filtered.isEmpty()) {
            Text(
                text = if (sessions.isEmpty()) "No threads yet" else "No matches",
                color = LitterTheme.textMuted,
                fontSize = LitterTextStyle.caption.scaled,
                modifier = Modifier
                    .align(Alignment.Center)
                    .padding(vertical = 24.dp),
            )
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = 4.dp),
            ) {
                items(
                    filtered,
                    key = { "${it.key.serverId}/${it.key.threadId}" },
                ) { session ->
                    val key = PinnedThreadKey(
                        serverId = session.key.serverId,
                        threadId = session.key.threadId,
                    )
                    val isPinned = pinnedKeys.contains(key)
                    ThreadSearchRow(
                        session = session,
                        isPinned = isPinned,
                        onToggle = {
                            if (isPinned) onUnpin(session) else onPin(session)
                        },
                    )
                    Divider(color = LitterTheme.border.copy(alpha = 0.15f))
                }
            }
        }
    }
}

@Composable
private fun ThreadSearchRow(
    session: AppSessionSummary,
    isPinned: Boolean,
    onToggle: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onToggle)
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = session.displayTitle,
                color = LitterTheme.textPrimary,
                fontSize = LitterTextStyle.caption.scaled,
                fontWeight = FontWeight.SemiBold,
                fontFamily = FontFamily.Monospace,
                maxLines = 1,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    text = session.serverDisplayName,
                    color = LitterTheme.accent.copy(alpha = 0.7f),
                    fontSize = 10f.scaled,
                    fontFamily = FontFamily.Monospace,
                )
                Text(
                    text = "\u00b7",
                    color = LitterTheme.textMuted.copy(alpha = 0.5f),
                    fontSize = 10f.scaled,
                )
                Text(
                    text = HomeDashboardSupport.workspaceLabel(session.cwd),
                    color = LitterTheme.textSecondary.copy(alpha = 0.8f),
                    fontSize = 10f.scaled,
                    fontFamily = FontFamily.Monospace,
                )
                val relative = HomeDashboardSupport.relativeTime(session.updatedAt)
                if (relative.isNotEmpty()) {
                    Text(
                        text = "\u00b7",
                        color = LitterTheme.textMuted.copy(alpha = 0.5f),
                        fontSize = 10f.scaled,
                    )
                    Text(
                        text = relative,
                        color = LitterTheme.textMuted.copy(alpha = 0.8f),
                        fontSize = 10f.scaled,
                        fontFamily = FontFamily.Monospace,
                    )
                }
            }
        }
        Spacer(Modifier.size(8.dp))
        Icon(
            imageVector = if (isPinned) Icons.Default.CheckCircle else Icons.Default.Add,
            contentDescription = null,
            tint = if (isPinned) LitterTheme.accent else LitterTheme.textPrimary,
            modifier = Modifier.size(20.dp),
        )
    }
}
