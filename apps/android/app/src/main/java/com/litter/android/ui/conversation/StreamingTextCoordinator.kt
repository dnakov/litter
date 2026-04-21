package com.litter.android.ui.conversation

import android.util.LruCache
import uniffi.codex_mobile_client.AppMessageRenderBlock
import uniffi.codex_mobile_client.MessageParser

/**
 * Tracks streaming text state per conversation item. Maintains a "frontier"
 * position so that stable (already-revealed) text can be cached and only the
 * newly-appended tail needs re-parsing and animation.
 *
 * The coordinator splits text at a markdown-safe boundary (blank line outside
 * of a code fence) so that the stable prefix is valid markdown.
 */
object StreamingTextCoordinator {

    data class StreamingTextState(
        /** Render blocks for the stable prefix — these don't change until the frontier advances. */
        val stableBlocks: List<AppMessageRenderBlock>,
        /** Render blocks for the frontier (new tokens). Rendered with fade-in animation. */
        val frontierBlocks: List<AppMessageRenderBlock>,
        /** The full text this state was computed from. */
        val fullText: String,
    )

    private data class CachedEntry(
        val fullText: String,
        val stablePrefix: String,
        val stableBlocks: List<AppMessageRenderBlock>,
        val frontierBlocks: List<AppMessageRenderBlock>,
    )

    /** How many characters of tail text we target for the frontier. */
    private const val TARGET_TAIL_CHARS = 512

    /** If the frontier grows past this, re-anchor the stable prefix forward. */
    private const val MAX_TAIL_CHARS = 2048

    /** Minimum stable prefix length before we bother caching it. */
    private const val MIN_REUSABLE_PREFIX = 256

    private val cache = LruCache<String, CachedEntry>(128)

    fun update(
        itemId: String,
        text: String,
        parser: MessageParser,
    ): StreamingTextState {
        val existing = cache.get(itemId)

        // Fast path: text unchanged
        if (existing != null && existing.fullText == text) {
            return StreamingTextState(
                stableBlocks = existing.stableBlocks,
                frontierBlocks = existing.frontierBlocks,
                fullText = text,
            )
        }

        // Can we reuse the existing stable prefix?
        if (existing != null &&
            existing.stablePrefix.isNotEmpty() &&
            text.startsWith(existing.stablePrefix)
        ) {
            val tailText = text.substring(existing.stablePrefix.length)
            if (tailText.length <= MAX_TAIL_CHARS) {
                val frontierBlocks = parser.extractRenderBlocksTyped(tailText)
                val entry = CachedEntry(
                    fullText = text,
                    stablePrefix = existing.stablePrefix,
                    stableBlocks = existing.stableBlocks,
                    frontierBlocks = frontierBlocks,
                )
                cache.put(itemId, entry)
                return StreamingTextState(
                    stableBlocks = entry.stableBlocks,
                    frontierBlocks = entry.frontierBlocks,
                    fullText = text,
                )
            }
        }

        // Need to (re)compute a stable anchor
        val anchor = stableAnchorOffset(text)
        val prefixText = text.substring(0, anchor)
        val tailText = text.substring(anchor)

        val stableBlocks = if (prefixText.isEmpty()) {
            emptyList()
        } else {
            parser.extractRenderBlocksTyped(prefixText)
        }
        val frontierBlocks = parser.extractRenderBlocksTyped(tailText)

        val entry = CachedEntry(
            fullText = text,
            stablePrefix = prefixText,
            stableBlocks = stableBlocks,
            frontierBlocks = frontierBlocks,
        )
        cache.put(itemId, entry)

        return StreamingTextState(
            stableBlocks = stableBlocks,
            frontierBlocks = frontierBlocks,
            fullText = text,
        )
    }

    /** Evict a specific item when streaming ends and the final result gets cached normally. */
    fun evict(itemId: String) {
        cache.remove(itemId)
    }

    fun clear() {
        cache.evictAll()
    }

    /**
     * Find a markdown-safe split point: the last blank line outside of a code fence,
     * leaving approximately [TARGET_TAIL_CHARS] for the tail.
     */
    private fun stableAnchorOffset(text: String): Int {
        if (text.length <= TARGET_TAIL_CHARS + MIN_REUSABLE_PREFIX) return 0

        val maxPrefixLen = (text.length - TARGET_TAIL_CHARS).coerceAtLeast(0)
        if (maxPrefixLen < MIN_REUSABLE_PREFIX) return 0

        var consumed = 0
        var insideFence = false
        var lastBlankBoundary = 0
        var lastLineBoundary = 0
        val lines = text.split('\n')

        for ((index, line) in lines.withIndex()) {
            val trimmed = line.trim()
            if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) {
                insideFence = !insideFence
            }

            consumed += line.length
            if (index < lines.size - 1) consumed += 1 // newline char

            if (consumed > maxPrefixLen || insideFence) continue

            lastLineBoundary = consumed
            if (trimmed.isEmpty()) {
                lastBlankBoundary = consumed
            }
        }

        if (lastBlankBoundary >= MIN_REUSABLE_PREFIX) return lastBlankBoundary
        if (lastLineBoundary >= MIN_REUSABLE_PREFIX) return lastLineBoundary
        return 0
    }
}
