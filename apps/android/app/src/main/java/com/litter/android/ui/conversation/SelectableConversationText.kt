package com.litter.android.ui.conversation

import android.text.method.LinkMovementMethod
import android.widget.TextView
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LocalTextScale
import io.noties.markwon.Markwon
import io.noties.markwon.syntax.SyntaxHighlightPlugin
import io.noties.prism4j.Prism4j

@Composable
internal fun SelectableConversationText(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    SelectionContainer(modifier = modifier) {
        content()
    }
}

@Composable
internal fun SelectableMarkdownText(
    text: String,
    modifier: Modifier = Modifier,
    bodySize: Float = LitterTextStyle.body,
    onTextViewReady: ((TextView) -> Unit)? = null,
) {
    val context = LocalContext.current
    val textScale = LocalTextScale.current
    val markwon = rememberConversationMarkwon(context)

    AndroidView(
        factory = { ctx ->
            TextView(ctx).apply {
                configureSelectableMarkdownTextView(
                    textView = this,
                    textColor = LitterTheme.textBody.toArgb(),
                    linkColor = LitterTheme.accent.toArgb(),
                    textSizeSp = bodySize * textScale,
                )
                onTextViewReady?.invoke(this)
            }
        },
        update = { tv ->
            configureSelectableMarkdownTextView(
                textView = tv,
                textColor = LitterTheme.textBody.toArgb(),
                linkColor = LitterTheme.accent.toArgb(),
                textSizeSp = bodySize * textScale,
            )
            markwon.setMarkdown(tv, text)
        },
        modifier = modifier,
    )
}

internal fun configureSelectableMarkdownTextView(
    textView: TextView,
    textColor: Int,
    linkColor: Int,
    textSizeSp: Float,
) {
    textView.setTextColor(textColor)
    textView.textSize = textSizeSp
    textView.linksClickable = true
    textView.movementMethod = LinkMovementMethod.getInstance()
    textView.setLinkTextColor(linkColor)
    textView.setTextIsSelectable(true)
}

@Composable
private fun rememberConversationMarkwon(context: android.content.Context): Markwon = remember(context) {
    try {
        val prism4j = Prism4j(com.litter.android.ui.Prism4jGrammarLocator())
        Markwon.builder(context)
            .usePlugin(
                SyntaxHighlightPlugin.create(
                    prism4j,
                    io.noties.markwon.syntax.Prism4jThemeDarkula.create(),
                ),
            )
            .build()
    } catch (_: Exception) {
        Markwon.create(context)
    }
}
