package com.litter.android.ui.home

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Build
import androidx.compose.material.icons.outlined.Computer
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.scaled
import uniffi.codex_mobile_client.AppToolLogEntry

/**
 * Single tool-log row rendered inside the home session card. Used at zoom 3+.
 *
 * Takes a Rust-derived [AppToolLogEntry] directly; the `tool` field is a
 * short category name (`"Bash"`, `"Edit"`, `"MCP"`, `"Tool"`, `"Explore"`,
 * `"WebSearch"`) and the `detail` is the rolled-up label (for `"Explore"`
 * it's the exploration summary, e.g. `"Explored 3 files"`).
 *
 * Ref: HomeDashboardView.swift (`toolRowView`, `toolIconView`).
 */
@Composable
fun HomeToolRowView(
    entry: AppToolLogEntry,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(
            modifier = Modifier.widthIn(min = 20.dp),
            contentAlignment = Alignment.CenterStart,
        ) {
            ToolIcon(tool = entry.tool)
        }
        Text(
            text = entry.detail,
            color = LitterTheme.textSecondary.copy(alpha = 0.8f),
            fontSize = LitterTextStyle.body.scaled,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun ToolIcon(tool: String) {
    val tint = LitterTheme.accent.copy(alpha = 0.6f)
    when (tool) {
        "MCP" -> Icon(
            imageVector = Icons.Outlined.Computer,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(12.dp),
        )
        "Tool" -> Icon(
            imageVector = Icons.Outlined.Build,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(12.dp),
        )
        else -> {
            val glyph = when (tool) {
                "Bash" -> "$"
                "Edit" -> "✎"
                "Explore", "WebSearch" -> "⌕"
                else -> tool.take(1).uppercase()
            }
            Text(
                text = glyph,
                color = tint,
                fontSize = 12f.scaled,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.defaultMinSize(minWidth = 12.dp),
            )
        }
    }
}
