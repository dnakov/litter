package com.litter.android.ui.conversation

import android.graphics.Typeface
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import android.view.View
import android.view.ViewGroup
import android.widget.HorizontalScrollView
import android.widget.TextView
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.isUnspecified
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LocalTextScale
import com.litter.android.ui.LitterTheme

@Composable
internal fun SyntaxHighlightedDiffBlock(
    diff: String,
    titleHint: String? = null,
    modifier: Modifier = Modifier,
    fontSize: TextUnit = TextUnit.Unspecified,
) {
    val textScale = LocalTextScale.current
    // When the caller omits fontSize, default to the shared caption size.
    // Non-composable default parameters can't call `.scaled`, so we resolve
    // it here and skip the per-call multiplier below for the default path.
    val resolvedFontPx: Float = if (fontSize.isUnspecified) {
        LitterTextStyle.caption * textScale
    } else {
        fontSize.value * textScale
    }
    val palette = remember(
        LitterTheme.textBody.toArgb(),
        LitterTheme.textSecondary.toArgb(),
        LitterTheme.success.toArgb(),
        LitterTheme.danger.toArgb(),
        LitterTheme.accentStrong.toArgb(),
        LitterTheme.codeBackground.toArgb(),
        LitterTheme.surface.copy(alpha = 0.72f).toArgb(),
    ) {
        DiffSyntaxPalette(
            context = LitterTheme.textBody.toArgb(),
            metadata = LitterTheme.textSecondary.toArgb(),
            addition = LitterTheme.success.toArgb(),
            deletion = LitterTheme.danger.toArgb(),
            hunk = LitterTheme.accentStrong.toArgb(),
            contextBackground = LitterTheme.codeBackground.toArgb(),
            metadataBackground = LitterTheme.surface.copy(alpha = 0.72f).toArgb(),
            additionBackground = LitterTheme.success.copy(alpha = 0.12f).toArgb(),
            deletionBackground = LitterTheme.danger.copy(alpha = 0.12f).toArgb(),
            hunkBackground = LitterTheme.accentStrong.copy(alpha = 0.12f).toArgb(),
        )
    }
    val highlighted = remember(diff, titleHint, palette) {
        buildHighlightedDiff(diff = diff, titleHint = titleHint, palette = palette)
    }

    AndroidView(
        factory = { context ->
            HorizontalScrollView(context).apply {
                overScrollMode = View.OVER_SCROLL_IF_CONTENT_SCROLLS
                isHorizontalScrollBarEnabled = true
                isFillViewport = false
                addView(
                    TextView(context).apply {
                        layoutParams = ViewGroup.LayoutParams(
                            ViewGroup.LayoutParams.WRAP_CONTENT,
                            ViewGroup.LayoutParams.WRAP_CONTENT,
                        )
                        typeface = Typeface.MONOSPACE
                        includeFontPadding = false
                        setHorizontallyScrolling(true)
                        setTextIsSelectable(true)
                    },
                )
            }
        },
        update = { scrollView ->
            val textView = scrollView.getChildAt(0) as TextView
            textView.typeface = Typeface.MONOSPACE
            textView.includeFontPadding = false
            textView.textSize = resolvedFontPx
            textView.setTextColor(LitterTheme.textBody.toArgb())
            textView.text = highlighted
        },
        modifier = modifier,
    )
}

private fun buildHighlightedDiff(
    diff: String,
    titleHint: String?,
    palette: DiffSyntaxPalette,
): CharSequence {
    val builder = SpannableStringBuilder()
    val lines = diff.lines()

    lines.forEachIndexed { index, rawLine ->
        val line = rawLine.ifEmpty { " " }
        val kind = DiffSyntaxLineKind.from(rawLine)
        val lineStart = builder.length
        builder.append(line)
        builder.setSpan(
            ForegroundColorSpan(kind.foreground(palette)),
            lineStart,
            builder.length,
            Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
        )

        val lineEnd = builder.length
        builder.setSpan(
            BackgroundColorSpan(kind.background(palette)),
            lineStart,
            lineEnd,
            Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
        )

        if (index < lines.lastIndex) {
            builder.append('\n')
        }
    }

    return builder
}

private data class DiffSyntaxPalette(
    val context: Int,
    val metadata: Int,
    val addition: Int,
    val deletion: Int,
    val hunk: Int,
    val contextBackground: Int,
    val metadataBackground: Int,
    val additionBackground: Int,
    val deletionBackground: Int,
    val hunkBackground: Int,
)

private enum class DiffSyntaxLineKind {
    ADDITION,
    DELETION,
    HUNK,
    METADATA,
    CONTEXT,
    ;

    fun foreground(palette: DiffSyntaxPalette): Int = when (this) {
        ADDITION -> palette.addition
        DELETION -> palette.deletion
        HUNK -> palette.hunk
        METADATA -> palette.metadata
        CONTEXT -> palette.context
    }

    fun background(palette: DiffSyntaxPalette): Int = when (this) {
        ADDITION -> palette.additionBackground
        DELETION -> palette.deletionBackground
        HUNK -> palette.hunkBackground
        METADATA -> palette.metadataBackground
        CONTEXT -> palette.contextBackground
    }

    companion object {
        fun from(text: String): DiffSyntaxLineKind = when {
            text.startsWith("@@") -> HUNK
            text.startsWith("+") && !text.startsWith("+++") -> ADDITION
            text.startsWith("-") && !text.startsWith("---") -> DELETION
            text.startsWith("diff --git ")
                || text.startsWith("index ")
                || text.startsWith("+++ ")
                || text.startsWith("--- ")
                || text.startsWith("new file mode ")
                || text.startsWith("deleted file mode ")
                || text.startsWith("rename from ")
                || text.startsWith("rename to ")
                || text.startsWith("similarity index ")
                || text.startsWith("Binary files ") -> METADATA
            else -> CONTEXT
        }
    }
}
