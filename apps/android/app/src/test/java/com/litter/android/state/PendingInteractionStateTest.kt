package com.litter.android.state

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PendingInteractionStateTest {
    @Test
    fun activePendingApprovalUsesFirstInteractionApproval() {
        val approval = PendingApproval(id = "approval-1", requestId = "approval-1", serverId = "server", method = "exec", kind = ApprovalKind.COMMAND_EXECUTION, threadId = null, turnId = null, itemId = null, command = null, cwd = null, reason = null, grantRoot = null)
        val state =
            AppState(
                pendingInteractions =
                    listOf(
                        PendingInteraction(
                            id = approval.id,
                            serverId = approval.serverId,
                            kind = PendingInteractionKind.APPROVAL,
                            approval = approval,
                        ),
                    ),
            )

        assertEquals(approval, state.activePendingApproval)
    }

    @Test
    fun activePendingApprovalIgnoresQuestionInteraction() {
        val question =
            PendingQuestion(
                id = "question-1",
                requestId = "question-1",
                serverId = "server",
                threadId = null,
                prompts = listOf(PendingQuestionPrompt(header = "Mode", question = "Choose", options = listOf(PendingQuestionOption("A", "desc")))),
            )
        val state =
            AppState(
                pendingInteractions =
                    listOf(
                        PendingInteraction(
                            id = question.id,
                            serverId = question.serverId,
                            kind = PendingInteractionKind.QUESTION,
                            question = question,
                        ),
                    ),
            )

        assertNull(state.activePendingApproval)
        assertEquals(question.id, state.activePendingInteraction?.question?.id)
    }
}
