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

/**
 * Single tool-log row rendered inside the home session card. Used at zoom 3+.
 *
 * Leading icon slot is pinned to a minimum width so adjacent rows stack
 * with aligned detail text. Text glyphs (`$`, `✎`, `·`, `⌕`) render as-is;
 * the two non-glyph markers (`mcp`, `tool`) become Material outlined icons.
 *
 * Ref: HomeDashboardView.swift:898-935 (`toolRowView`, `toolIconView`).
 */
@Composable
fun HomeToolRowView(
    row: HomeToolRow,
    modifier: Modifier = Modifier,
) {
    val (icon, detail) = when (row) {
        is HomeToolRow.Exploration -> "⌕" to row.summary
        is HomeToolRow.Tool -> row.icon to row.detail
    }

    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(
            modifier = Modifier.widthIn(min = 20.dp),
            contentAlignment = Alignment.CenterStart,
        ) {
            ToolIcon(icon)
        }
        Text(
            text = detail,
            color = LitterTheme.textSecondary.copy(alpha = 0.8f),
            fontSize = LitterTextStyle.body.scaled,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun ToolIcon(icon: String) {
    val tint = LitterTheme.accent.copy(alpha = 0.6f)
    when (icon) {
        "mcp" -> Icon(
            imageVector = Icons.Outlined.Computer,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(12.dp),
        )
        "tool" -> Icon(
            imageVector = Icons.Outlined.Build,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(12.dp),
        )
        else -> Text(
            text = icon,
            color = tint,
            fontSize = 12f.scaled,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.defaultMinSize(minWidth = 12.dp),
        )
    }
}
