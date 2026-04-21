package com.litter.android.ui.home

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.state.displayTitle
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.scaled
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.AppSessionSummary
import uniffi.codex_mobile_client.ThreadKey

/**
 * Minimal reply composer shown when the user swipes right on a home session row.
 * Mirrors iOS `QuickReplySheet.swift`. Calls [onSend] with the trimmed text and
 * dismisses on success.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun QuickReplySheet(
    thread: AppSessionSummary,
    onDismiss: () -> Unit,
    onSend: suspend (ThreadKey, String) -> Result<Unit>,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    val focusRequester = remember { FocusRequester() }

    var text by remember { mutableStateOf("") }
    var isSending by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    val canSend = !isSending && text.trim().isNotEmpty()

    LaunchedEffect(Unit) {
        delay(150)
        runCatching { focusRequester.requestFocus() }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = LitterTheme.background,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                text = thread.displayTitle,
                color = LitterTheme.textPrimary,
                fontSize = LitterTextStyle.body.scaled,
                fontWeight = FontWeight.SemiBold,
                maxLines = 2,
            )

            Text(
                text = buildString {
                    append(thread.serverDisplayName)
                    append(" \u00b7 ")
                    append(HomeDashboardSupport.workspaceLabel(thread.cwd))
                },
                color = LitterTheme.textMuted,
                fontSize = LitterTextStyle.caption2.scaled,
                fontFamily = FontFamily.Monospace,
                maxLines = 1,
            )

            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(LitterTheme.surface)
                    .border(
                        width = 0.5.dp,
                        color = LitterTheme.border,
                        shape = RoundedCornerShape(10.dp),
                    ),
            ) {
                TextField(
                    value = text,
                    onValueChange = { text = it },
                    placeholder = {
                        Text(
                            text = "Reply\u2026",
                            color = LitterTheme.textMuted,
                        )
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 52.dp, max = 220.dp)
                        .focusRequester(focusRequester),
                    colors = TextFieldDefaults.colors(
                        focusedContainerColor = Color.Transparent,
                        unfocusedContainerColor = Color.Transparent,
                        disabledContainerColor = Color.Transparent,
                        focusedIndicatorColor = Color.Transparent,
                        unfocusedIndicatorColor = Color.Transparent,
                        disabledIndicatorColor = Color.Transparent,
                        focusedTextColor = LitterTheme.textPrimary,
                        unfocusedTextColor = LitterTheme.textPrimary,
                        cursorColor = LitterTheme.accent,
                    ),
                )
            }

            errorMessage?.let { message ->
                Text(
                    text = message,
                    color = LitterTheme.danger,
                    fontSize = LitterTextStyle.caption2.scaled,
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (isSending) {
                    CircularProgressIndicator(
                        color = LitterTheme.accent,
                        strokeWidth = 2.dp,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                }
                IconButton(
                    enabled = canSend,
                    onClick = {
                        val trimmed = text.trim()
                        if (trimmed.isEmpty() || isSending) return@IconButton
                        isSending = true
                        errorMessage = null
                        scope.launch {
                            val result = onSend(thread.key, trimmed)
                            isSending = false
                            result.onSuccess {
                                onDismiss()
                            }.onFailure { err ->
                                errorMessage = err.message ?: "Failed to send"
                            }
                        }
                    },
                    modifier = Modifier
                        .size(36.dp)
                        .clip(CircleShape)
                        .background(
                            color = if (canSend) LitterTheme.accent else LitterTheme.surfaceLight,
                        ),
                ) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.Send,
                        contentDescription = "Send",
                        tint = if (canSend) Color.Black else LitterTheme.textMuted,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }

            Spacer(Modifier.size(4.dp))
        }
    }
}
