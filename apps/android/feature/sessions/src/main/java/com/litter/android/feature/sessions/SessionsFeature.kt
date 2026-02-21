package com.litter.android.feature.sessions

import com.litter.android.core.bridge.CodexRpcClient
import com.litter.android.core.bridge.SessionSummary

class SessionsFeature(
    private val rpcClient: CodexRpcClient,
) {
    fun loadSessions(): List<SessionSummary> = rpcClient.listSessions()
}
