package com.litter.android.feature.conversation

import com.litter.android.core.bridge.CodexRpcClient

class ConversationFeature(
    private val rpcClient: CodexRpcClient,
) {
    fun sendPrompt(prompt: String): String = rpcClient.startTurn(prompt)
}
