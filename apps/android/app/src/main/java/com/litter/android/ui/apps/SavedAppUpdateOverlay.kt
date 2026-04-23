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
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.scaled

@Composable
fun SavedAppUpdateOverlay(
    currentTitle: String,
    onDismiss: () -> Unit,
    onSubmit: (String) -> Unit,
    isSubmitting: Boolean,
) {
    var prompt by remember { mutableStateOf("") }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.55f))
            .pointerInput(isSubmitting) {
                // Consume taps so they don't fall through to the underlying
                // WebView. Dismiss on tap outside the card only when not
                // submitting.
                awaitPointerEventScope {
                    while (true) {
                        val event = awaitPointerEvent()
                        if (!isSubmitting) {
                            event.changes.forEach { it.consume() }
                        } else {
                            event.changes.forEach { it.consume() }
                        }
                    }
                }
            }
            .clickable(enabled = !isSubmitting, onClick = onDismiss),
        contentAlignment = Alignment.BottomCenter,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp)
                .navigationBarsPadding()
                .imePadding()
                .clip(RoundedCornerShape(18.dp))
                .background(LitterTheme.surface)
                .clickable(enabled = false, onClick = {})
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = if (isSubmitting) "Updating \"$currentTitle\"" else "Update App",
                    color = LitterTheme.textPrimary,
                    fontSize = LitterTextStyle.headline.scaled,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                if (!isSubmitting) {
                    IconButton(onClick = onDismiss) {
                        Icon(
                            Icons.Default.Close,
                            contentDescription = "Close",
                            tint = LitterTheme.textSecondary,
                        )
                    }
                }
            }

            if (isSubmitting) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(18.dp),
                        strokeWidth = 2.dp,
                        color = LitterTheme.accent,
                    )
                    Text(
                        text = "Working on your update…",
                        color = LitterTheme.textSecondary,
                        fontSize = LitterTextStyle.footnote.scaled,
                    )
                }
            } else {
                Text(
                    text = "Describe the change. The model keeps your saved state.",
                    color = LitterTheme.textSecondary,
                    fontSize = LitterTextStyle.footnote.scaled,
                )
                OutlinedTextField(
                    value = prompt,
                    onValueChange = { prompt = it },
                    placeholder = { Text("e.g. make the buttons bigger") },
                    modifier = Modifier.fillMaxWidth(),
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.End,
                ) {
                    TextButton(onClick = onDismiss) {
                        Text("Cancel", color = LitterTheme.textSecondary)
                    }
                    Spacer(Modifier.size(8.dp))
                    TextButton(
                        enabled = prompt.isNotBlank(),
                        onClick = {
                            val value = prompt.trim()
                            if (value.isNotEmpty()) onSubmit(value)
                        },
                    ) {
                        Text("Submit", color = LitterTheme.accent)
                    }
                }
            }
        }
    }
}
