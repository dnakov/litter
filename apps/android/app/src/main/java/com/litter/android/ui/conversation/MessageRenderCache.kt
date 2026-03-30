package com.litter.android.ui.conversation

import android.util.LruCache
import uniffi.codex_mobile_client.AppMessageSegment
import uniffi.codex_mobile_client.AppToolCallCard
import uniffi.codex_mobile_client.MessageParser

/**
 * LRU cache for expensive message parsing results.
 * Keyed by (itemId, serverId, agentDirectoryVersion) to invalidate on changes.
 * Calls Rust [MessageParser] and caches the typed result.
 */
object MessageRenderCache {

    data class CacheKey(
        val itemId: String,
        val serverId: String,
        val agentDirectoryVersion: ULong,
    )

    private val segmentCache = LruCache<CacheKey, List<AppMessageSegment>>(1024)
    private val toolCallCache = LruCache<CacheKey, List<AppToolCallCard>>(1024)

    fun getSegments(
        key: CacheKey,
        parser: MessageParser,
        text: String,
    ): List<AppMessageSegment> {
        segmentCache.get(key)?.let { return it }
        val segments = parser.extractSegmentsTyped(text)
        segmentCache.put(key, segments)
        return segments
    }

    fun getToolCalls(
        key: CacheKey,
        parser: MessageParser,
        text: String,
    ): List<AppToolCallCard> {
        toolCallCache.get(key)?.let { return it }
        val cards = parser.parseToolCallsTyped(text)
        toolCallCache.put(key, cards)
        return cards
    }

    fun clear() {
        segmentCache.evictAll()
        toolCallCache.evictAll()
    }
}
