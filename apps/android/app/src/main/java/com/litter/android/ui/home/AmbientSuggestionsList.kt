package com.litter.android.ui.home

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.LitterTheme
import uniffi.codex_mobile_client.AmbientSuggestion

@Composable
fun AmbientSuggestionsList(
    suggestions: List<AmbientSuggestion>,
    onPick: (AmbientSuggestion) -> Unit,
    modifier: Modifier = Modifier,
) {
    val capped = suggestions.take(4)
    Column(modifier = modifier.fillMaxWidth()) {
        capped.forEachIndexed { index, suggestion ->
            if (index > 0) {
                HorizontalDivider(
                    color = LitterTheme.textMuted.copy(alpha = 0.2f),
                    thickness = 0.5.dp,
                )
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onPick(suggestion) }
                    .padding(horizontal = 14.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    imageVector = Icons.AutoMirrored.Outlined.Chat,
                    contentDescription = null,
                    tint = LitterTheme.textMuted,
                    modifier = Modifier.size(14.dp),
                )
                Spacer(Modifier.width(10.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = suggestion.title ?: suggestion.prompt ?: suggestion.id,
                        color = LitterTheme.textSecondary,
                        fontSize = 13.sp,
                        maxLines = 1,
                    )
                    val desc = suggestion.description
                    if (!desc.isNullOrBlank()) {
                        Text(
                            text = desc,
                            color = LitterTheme.textMuted,
                            fontSize = 11.sp,
                            maxLines = 1,
                        )
                    }
                }
            }
        }
    }
}
