package com.litter.android.ui.sessions

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import uniffi.codex_mobile_client.ThreadKey

@Stable
class SessionsUiState {
    var showOnlyForks by mutableStateOf(false)
    var sortMode by mutableStateOf(WorkspaceSortMode.RECENT)
    var collapsedWorkspaceGroupKeys by mutableStateOf(emptySet<String>())
    var collapsedSessionNodeKeys by mutableStateOf(emptySet<ThreadKey>())

    fun toggleWorkspaceGroup(groupKey: String) {
        collapsedWorkspaceGroupKeys = if (groupKey in collapsedWorkspaceGroupKeys) {
            collapsedWorkspaceGroupKeys - groupKey
        } else {
            collapsedWorkspaceGroupKeys + groupKey
        }
    }

    fun expandWorkspaceGroup(groupKey: String) {
        if (groupKey in collapsedWorkspaceGroupKeys) {
            collapsedWorkspaceGroupKeys = collapsedWorkspaceGroupKeys - groupKey
        }
    }

    fun pruneWorkspaceGroupKeys(validKeys: Set<String>) {
        collapsedWorkspaceGroupKeys = collapsedWorkspaceGroupKeys.intersect(validKeys)
    }

    fun toggleSessionNode(threadKey: ThreadKey) {
        collapsedSessionNodeKeys = if (threadKey in collapsedSessionNodeKeys) {
            collapsedSessionNodeKeys - threadKey
        } else {
            collapsedSessionNodeKeys + threadKey
        }
    }

    fun expandSessionNode(threadKey: ThreadKey) {
        if (threadKey in collapsedSessionNodeKeys) {
            collapsedSessionNodeKeys = collapsedSessionNodeKeys - threadKey
        }
    }

    fun pruneSessionNodeKeys(validKeys: Set<ThreadKey>) {
        collapsedSessionNodeKeys = collapsedSessionNodeKeys.intersect(validKeys)
    }
}
