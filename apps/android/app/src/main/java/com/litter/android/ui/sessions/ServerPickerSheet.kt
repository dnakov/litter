package com.litter.android.ui.sessions

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.LitterTheme

@Composable
fun ServerPickerSheet(
    servers: List<ServerPickerOption>,
    initialServerId: String,
    onSelect: (ServerPickerOption) -> Unit,
    onDismiss: () -> Unit,
) {
    var searchQuery by remember { mutableStateOf("") }
    val filteredServers = remember(servers, searchQuery) {
        val query = searchQuery.trim()
        if (query.isBlank()) {
            servers
        } else {
            servers.filter { server ->
                server.name.contains(query, ignoreCase = true) ||
                    server.backendLabel.contains(query, ignoreCase = true) ||
                    server.transportLabel.contains(query, ignoreCase = true) ||
                    server.connectionPathLabel.contains(query, ignoreCase = true) ||
                    server.lastUsedDirectoryHint?.contains(query, ignoreCase = true) == true ||
                    server.defaultModelLabel?.contains(query, ignoreCase = true) == true
            }
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .fillMaxHeight(0.94f)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            text = "Pick Server",
            color = LitterTheme.textPrimary,
            fontSize = 18.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Text(
            text = "Choose a backend first. Workspace selection comes next.",
            color = LitterTheme.textSecondary,
            fontSize = 12.sp,
        )

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.surface, RoundedCornerShape(8.dp))
                .padding(horizontal = 10.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Default.Search, contentDescription = null, tint = LitterTheme.textMuted)
            Spacer(Modifier.size(8.dp))
            Box(modifier = Modifier.weight(1f)) {
                if (searchQuery.isEmpty()) {
                    Text("Search servers", color = LitterTheme.textMuted, fontSize = 13.sp)
                }
                BasicTextField(
                    value = searchQuery,
                    onValueChange = { searchQuery = it },
                    textStyle = TextStyle(color = LitterTheme.textPrimary, fontSize = 13.sp),
                    cursorBrush = SolidColor(LitterTheme.accent),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }

        LazyColumn(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            items(filteredServers, key = { it.id }) { server ->
                val isSuggested = server.id == initialServerId
                ServerPickerRow(
                    server = server,
                    isSuggested = isSuggested,
                    onClick = { onSelect(server) },
                )
            }
        }

        Button(
            onClick = onDismiss,
            modifier = Modifier.fillMaxWidth(),
            colors = ButtonDefaults.buttonColors(
                containerColor = LitterTheme.surface,
                contentColor = LitterTheme.textPrimary,
            ),
        ) {
            Text("Cancel")
        }
    }
}

@Composable
private fun ServerPickerRow(
    server: ServerPickerOption,
    isSuggested: Boolean,
    onClick: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(8.dp))
            .clickable(onClick = onClick)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .background(LitterTheme.accent, CircleShape),
            )
            Spacer(Modifier.size(8.dp))
            Text(
                text = server.name,
                color = LitterTheme.textPrimary,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                modifier = Modifier.weight(1f),
            )
            if (isSuggested) {
                Text(
                    text = "Current",
                    color = Color.Black,
                    fontSize = 10.sp,
                    modifier = Modifier
                        .background(LitterTheme.accent, RoundedCornerShape(4.dp))
                        .padding(horizontal = 6.dp, vertical = 2.dp),
                )
            }
        }

        Text(
            text = server.subtitle,
            color = LitterTheme.textSecondary,
            fontSize = 12.sp,
        )

        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            SummaryChip(server.backendLabel, LitterTheme.accent)
            SummaryChip(server.transportLabel, LitterTheme.info)
            SummaryChip(server.statusLabel, LitterTheme.textSecondary)
        }

        server.lastUsedDirectoryHint?.let { directory ->
            Text(
                text = directory,
                color = LitterTheme.textMuted,
                fontSize = 11.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = server.defaultModelLabel?.let { "Default model: $it" } ?: server.modelCatalogCountLabel,
                color = LitterTheme.textMuted,
                fontSize = 11.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            Text(
                text = if (server.backendKind.name == "OPEN_CODE") {
                    "${server.knownDirectories.size} scopes"
                } else if (server.canBrowseDirectories) {
                    "Browse"
                } else {
                    "Select"
                },
                color = LitterTheme.accent,
                fontSize = 11.sp,
            )
        }
    }
}

@Composable
private fun SummaryChip(
    label: String,
    color: Color,
) {
    Text(
        text = label,
        color = color,
        fontSize = 10.sp,
        modifier = Modifier
            .background(color.copy(alpha = 0.12f), RoundedCornerShape(4.dp))
            .padding(horizontal = 6.dp, vertical = 2.dp),
    )
}
