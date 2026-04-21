package com.litter.android.ui.home

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.scaled
import uniffi.codex_mobile_client.AppProject
import uniffi.codex_mobile_client.projectDefaultLabel

@Composable
fun ProjectChip(
    project: AppProject?,
    disabled: Boolean,
    onTap: () -> Unit,
) {
    val label = when {
        project != null -> projectDefaultLabel(project.cwd)
        disabled -> "no server"
        else -> "pick project"
    }
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(20.dp))
            .background(LitterTheme.surface.copy(alpha = 0.9f))
            .border(0.8.dp, LitterTheme.textMuted.copy(alpha = 0.55f), RoundedCornerShape(20.dp))
            .clickable(enabled = !disabled, onClick = onTap)
            .padding(horizontal = 10.dp, vertical = 5.dp)
            .alpha(if (disabled) 0.5f else 1f),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(
            imageVector = Icons.Default.Folder,
            contentDescription = null,
            tint = if (project != null) LitterTheme.accent else LitterTheme.textMuted,
            modifier = Modifier.size(12.dp),
        )
        Text(
            text = label,
            color = if (project != null) LitterTheme.textPrimary else LitterTheme.textSecondary,
            fontSize = LitterTextStyle.caption.scaled,
            fontWeight = FontWeight.Medium,
            fontFamily = LitterTheme.monoFont,
            maxLines = 1,
        )
        Icon(
            imageVector = Icons.Default.UnfoldMore,
            contentDescription = null,
            tint = LitterTheme.textMuted,
            modifier = Modifier.size(12.dp),
        )
    }
}
