package com.litter.android.ui.home

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Reply
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.litter.android.state.AppComposerPayload
import com.litter.android.state.AppModel
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.common.SwipeAction
import com.litter.android.ui.common.SwipeableRow
import uniffi.codex_mobile_client.AppSessionSummary

/**
 * Wraps a session row with a right-swipe "reply" gesture. When the user
 * releases past the commit threshold, a [QuickReplySheet] opens pre-targeted
 * at the session's thread. Mirrors iOS `SessionReplySwipe.swift`.
 *
 * An optional [trailingAction] is forwarded to the inner [SwipeableRow] so
 * the same row can host both a reply swipe (leading) and a hide/archive
 * swipe (trailing) — nesting two separate swipe wrappers would have the
 * inner and outer gesture handlers fighting over the same pointer stream.
 *
 * The send path mirrors iOS `LitterApp.swift:1043-1078` — the thread is
 * resumed before `startTurn` is called so the server can find it when the
 * home list was populated from a cold-launch snapshot.
 */
@Composable
fun SessionReplySwipe(
    session: AppSessionSummary,
    appModel: AppModel,
    modifier: Modifier = Modifier,
    trailingAction: SwipeAction? = null,
    onError: (String) -> Unit = {},
    content: @Composable () -> Unit,
) {
    var isSheetVisible by remember { mutableStateOf(false) }

    SwipeableRow(
        leadingAction = SwipeAction(
            icon = Icons.AutoMirrored.Filled.Reply,
            label = "reply",
            tint = LitterTheme.accent,
            onTrigger = { isSheetVisible = true },
        ),
        trailingAction = trailingAction,
        modifier = modifier,
    ) {
        content()
    }

    if (isSheetVisible) {
        QuickReplySheet(
            thread = session,
            onDismiss = { isSheetVisible = false },
            onSend = { threadKey, text ->
                runCatching {
                    // Resume the thread first so the server can find it —
                    // cold-launch snapshots have the thread hydrated locally
                    // but not yet registered with the upstream session.
                    val resumeKey = appModel.hydrateThreadPermissions(threadKey) ?: threadKey
                    try {
                        appModel.externalResumeThread(resumeKey)
                    } catch (_: Exception) {
                        val cwdOverride = appModel.threadSnapshot(resumeKey)?.info?.cwd
                        appModel.client.resumeThread(
                            resumeKey.serverId,
                            appModel.launchState.threadResumeRequest(
                                resumeKey.threadId,
                                cwdOverride = cwdOverride,
                                threadKey = resumeKey,
                            ),
                        )
                    }
                    val payload = AppComposerPayload(
                        text = text,
                        additionalInputs = emptyList(),
                        approvalPolicy = appModel.launchState.approvalPolicyValue(resumeKey),
                        sandboxPolicy = appModel.launchState.turnSandboxPolicy(resumeKey),
                        model = appModel.launchState.snapshot.value.selectedModel
                            .trim().ifEmpty { null },
                        reasoningEffort = null,
                        serviceTier = null,
                    )
                    appModel.startTurn(resumeKey, payload)
                    appModel.refreshThreadSnapshot(resumeKey)
                }.onFailure { err ->
                    onError(err.message ?: "Failed to send reply")
                }
            },
        )
    }
}
