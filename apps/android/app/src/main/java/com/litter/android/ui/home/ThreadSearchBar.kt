package com.litter.android.ui.home

import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.scaled

/**
 * Glass-ish capsule that morphs into a focused search field when tapped.
 * Caller controls expanded state and reads the query via callbacks so it
 * can render the results list alongside.
 */
@Composable
fun ThreadSearchBar(
    query: String,
    isExpanded: Boolean,
    onQueryChange: (String) -> Unit,
    onExpandChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    val focusRequester = remember { FocusRequester() }

    LaunchedEffect(isExpanded) {
        if (isExpanded) {
            focusRequester.requestFocus()
        }
    }

    Row(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = if (isExpanded) Arrangement.Start else Arrangement.End,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val rowModifier = if (isExpanded) {
            Modifier.fillMaxWidth()
        } else {
            Modifier.wrapContentWidth()
        }

        Row(
            modifier = rowModifier
                .animateContentSize(
                    animationSpec = spring(
                        dampingRatio = Spring.DampingRatioLowBouncy,
                        stiffness = Spring.StiffnessMediumLow,
                    ),
                )
                .background(
                    color = LitterTheme.textPrimary.copy(alpha = 0.06f),
                    shape = CircleShape,
                )
                .border(
                    width = if (isExpanded) 1.dp else 0.5.dp,
                    color = if (isExpanded) LitterTheme.accent.copy(alpha = 0.5f)
                    else LitterTheme.textMuted.copy(alpha = 0.25f),
                    shape = CircleShape,
                )
                .clickable(enabled = !isExpanded) { onExpandChange(true) }
                .padding(
                    horizontal = if (isExpanded) 12.dp else 12.dp,
                    vertical = if (isExpanded) 6.dp else 6.dp,
                ),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Default.Search,
                contentDescription = null,
                tint = if (isExpanded) LitterTheme.accent else LitterTheme.textSecondary,
                modifier = Modifier.size(14.dp),
            )
            Box(modifier = Modifier.width(6.dp))

            if (isExpanded) {
                BasicTextField(
                    value = query,
                    onValueChange = onQueryChange,
                    modifier = Modifier
                        .fillMaxWidth()
                        .focusRequester(focusRequester),
                    textStyle = TextStyle(
                        color = LitterTheme.textPrimary,
                        fontSize = LitterTextStyle.code.scaled,
                        fontFamily = FontFamily.Monospace,
                    ),
                    singleLine = true,
                    cursorBrush = SolidColor(LitterTheme.accent),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    decorationBox = { inner ->
                        Box {
                            if (query.isEmpty()) {
                                Text(
                                    text = "search threads",
                                    color = LitterTheme.textSecondary,
                                    fontSize = LitterTextStyle.code.scaled,
                                    fontFamily = FontFamily.Monospace,
                                )
                            }
                            inner()
                        }
                    },
                )
                IconButton(
                    onClick = {
                        onQueryChange("")
                        onExpandChange(false)
                    },
                    modifier = Modifier.size(22.dp),
                ) {
                    Icon(
                        Icons.Default.Close,
                        contentDescription = "Close",
                        tint = LitterTheme.textMuted,
                        modifier = Modifier.size(14.dp),
                    )
                }
            } else {
                Text(
                    text = "search threads",
                    color = LitterTheme.textSecondary,
                    fontSize = LitterTextStyle.caption.scaled,
                    fontFamily = FontFamily.Monospace,
                    textAlign = TextAlign.Start,
                )
            }
        }
    }
}
