package com.litter.android.ui.conversation

import android.graphics.BitmapFactory
import android.text.method.LinkMovementMethod
import android.widget.TextView
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LocalTextScale
import com.litter.android.ui.scaled
import io.noties.markwon.Markwon
import io.noties.markwon.syntax.SyntaxHighlightPlugin
import io.noties.prism4j.Prism4j
import uniffi.codex_mobile_client.AppMessageRenderBlock

/**
 * Composable that renders streaming assistant messages with a fade-in reveal
 * effect on newly appended tokens. Uses [StreamingTextCoordinator] to split
 * text into a stable cached prefix and an animated frontier.
 */
@Composable
fun StreamingMarkdownView(
    text: String,
    itemId: String,
    onRendered: (() -> Unit)? = null,
    bodySize: Float = LitterTextStyle.body,
) {
    val appModel = LocalAppModel.current

    // Compute streaming state — stable prefix blocks are cached, frontier blocks animate
    val streamState = remember(itemId, text) {
        StreamingTextCoordinator.update(
            itemId = itemId,
            text = text,
            parser = appModel.parser,
        )
    }

    // Animate frontier alpha: snap to 0 on new text, then animate to 1
    val frontierAlpha = remember(itemId) { Animatable(1f) }

    LaunchedEffect(text) {
        frontierAlpha.snapTo(0f)
        frontierAlpha.animateTo(1f, animationSpec = tween(durationMillis = 150))
        onRendered?.invoke()
    }

    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Render stable prefix blocks (fully opaque, cached)
        if (streamState.stableBlocks.isNotEmpty()) {
            StreamingRenderBlocks(
                blocks = streamState.stableBlocks,
                alpha = 1f,
                bodySize = bodySize,
            )
        }

        // Render frontier blocks with fade-in
        if (streamState.frontierBlocks.isNotEmpty()) {
            StreamingRenderBlocks(
                blocks = streamState.frontierBlocks,
                alpha = frontierAlpha.value,
                bodySize = bodySize,
            )
        }
    }
}

@Composable
private fun StreamingRenderBlocks(
    blocks: List<AppMessageRenderBlock>,
    alpha: Float,
    bodySize: Float,
) {
    blocks.forEachIndexed { index, block ->
        when (block) {
            is AppMessageRenderBlock.Markdown -> {
                if (block.markdown.isNotEmpty()) {
                    StreamingMarkdownText(
                        text = block.markdown,
                        modifier = Modifier.alpha(alpha),
                        bodySize = bodySize,
                    )
                }
            }
            is AppMessageRenderBlock.CodeBlock -> {
                StreamingCodeBlock(
                    language = block.language,
                    code = block.code,
                    modifier = Modifier.alpha(alpha),
                    bodySize = bodySize,
                )
            }
            is AppMessageRenderBlock.InlineImage -> {
                val bitmap = remember(block.data) {
                    BitmapFactory.decodeByteArray(block.data, 0, block.data.size)
                }
                bitmap?.let {
                    Image(
                        bitmap = it.asImageBitmap(),
                        contentDescription = "Assistant image",
                        modifier = Modifier
                            .alpha(alpha)
                            .fillMaxWidth()
                            .heightIn(max = 300.dp)
                            .clip(RoundedCornerShape(10.dp)),
                    )
                }
            }
        }
    }
}

@Composable
private fun StreamingMarkdownText(
    text: String,
    modifier: Modifier = Modifier,
    bodySize: Float = LitterTextStyle.body,
) {
    val context = LocalContext.current
    val textScale = LocalTextScale.current
    val markwon = remember(context) {
        try {
            val prism4j = Prism4j(com.litter.android.ui.Prism4jGrammarLocator())
            Markwon.builder(context)
                .usePlugin(SyntaxHighlightPlugin.create(prism4j, io.noties.markwon.syntax.Prism4jThemeDarkula.create()))
                .build()
        } catch (_: Exception) {
            Markwon.create(context)
        }
    }

    AndroidView(
        factory = { ctx ->
            TextView(ctx).apply {
                setTextColor(LitterTheme.textBody.toArgb())
                textSize = bodySize * textScale
                movementMethod = LinkMovementMethod.getInstance()
                setLinkTextColor(LitterTheme.accent.toArgb())
            }
        },
        update = { tv ->
            tv.setTextColor(LitterTheme.textBody.toArgb())
            tv.textSize = bodySize * textScale
            markwon.setMarkdown(tv, text)
        },
        modifier = modifier.fillMaxWidth(),
    )
}

@Composable
private fun StreamingCodeBlock(
    language: String?,
    code: String,
    modifier: Modifier = Modifier,
    bodySize: Float = LitterTextStyle.body,
) {
    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        language?.takeIf { it.isNotBlank() }?.let {
            Text(
                text = it.uppercase(),
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.caption2.scaled,
                fontWeight = FontWeight.Bold,
            )
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.codeBackground, RoundedCornerShape(8.dp))
                .padding(10.dp),
        ) {
            Text(
                text = code,
                color = LitterTheme.textBody,
                fontFamily = LitterTheme.monoFont,
                fontSize = bodySize.scaled,
                modifier = Modifier.horizontalScroll(rememberScrollState()),
            )
        }
    }
}
