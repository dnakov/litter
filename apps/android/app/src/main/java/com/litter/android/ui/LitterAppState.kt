package com.litter.android.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import com.litter.android.core.network.DiscoveredServer
import com.litter.android.core.network.DiscoverySource
import com.litter.android.core.network.ServerDiscoveryService
import com.litter.android.state.AccountState
import com.litter.android.state.AppState
import com.litter.android.state.AuthStatus
import com.litter.android.state.ChatMessage
import com.litter.android.state.ModelOption
import com.litter.android.state.ModelSelection
import com.litter.android.state.SavedSshCredential
import com.litter.android.state.ServerConfig
import com.litter.android.state.ServerConnectionStatus
import com.litter.android.state.ServerManager
import com.litter.android.state.ServerSource
import com.litter.android.state.SshAuthMethod
import com.litter.android.state.SshCredentialStore
import com.litter.android.state.SshCredentials
import com.litter.android.state.SshSessionManager
import com.litter.android.state.ThreadKey
import com.litter.android.state.ThreadState
import com.litter.android.state.ThreadStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.io.Closeable

data class DirectoryPickerUiState(
    val isVisible: Boolean = false,
    val currentPath: String = "",
    val entries: List<String> = emptyList(),
    val isLoading: Boolean = false,
    val errorMessage: String? = null,
)

data class UiDiscoveredServer(
    val id: String,
    val name: String,
    val host: String,
    val port: Int,
    val source: DiscoverySource,
    val hasCodexServer: Boolean,
)

data class DiscoveryUiState(
    val isVisible: Boolean = false,
    val isLoading: Boolean = false,
    val servers: List<UiDiscoveredServer> = emptyList(),
    val manualHost: String = "",
    val manualPort: String = "8390",
    val errorMessage: String? = null,
)

data class SshLoginUiState(
    val isVisible: Boolean = false,
    val serverId: String? = null,
    val serverName: String = "",
    val host: String = "",
    val port: Int = 22,
    val username: String = "",
    val password: String = "",
    val useKey: Boolean = false,
    val privateKey: String = "",
    val passphrase: String = "",
    val rememberCredentials: Boolean = true,
    val hasSavedCredentials: Boolean = false,
    val isConnecting: Boolean = false,
    val errorMessage: String? = null,
)

data class UiShellState(
    val isSidebarOpen: Boolean = false,
    val connectionStatus: ServerConnectionStatus = ServerConnectionStatus.DISCONNECTED,
    val connectionError: String? = null,
    val connectedServers: List<ServerConfig> = emptyList(),
    val activeServerId: String? = null,
    val serverCount: Int = 0,
    val models: List<ModelOption> = emptyList(),
    val selectedModelId: String? = null,
    val selectedReasoningEffort: String? = "medium",
    val sessions: List<ThreadState> = emptyList(),
    val activeThreadKey: ThreadKey? = null,
    val messages: List<ChatMessage> = emptyList(),
    val draft: String = "",
    val isSending: Boolean = false,
    val currentCwd: String = "/",
    val directoryPicker: DirectoryPickerUiState = DirectoryPickerUiState(),
    val discovery: DiscoveryUiState = DiscoveryUiState(),
    val showSettings: Boolean = false,
    val showAccount: Boolean = false,
    val accountOpenedFromSettings: Boolean = false,
    val accountState: AccountState = AccountState(),
    val apiKeyDraft: String = "",
    val isAuthWorking: Boolean = false,
    val sshLogin: SshLoginUiState = SshLoginUiState(),
    val uiError: String? = null,
)

interface LitterAppState : Closeable {
    val uiState: StateFlow<UiShellState>

    fun toggleSidebar()

    fun dismissSidebar()

    fun selectModel(modelId: String)

    fun selectReasoningEffort(effort: String)

    fun selectSession(threadKey: ThreadKey)

    fun updateDraft(value: String)

    fun refreshSessions()

    fun openNewSessionPicker()

    fun dismissDirectoryPicker()

    fun navigateDirectoryInto(entry: String)

    fun navigateDirectoryUp()

    fun confirmStartSessionFromPicker()

    fun sendDraft()

    fun interrupt()

    fun openSettings()

    fun dismissSettings()

    fun openAccount()

    fun dismissAccount()

    fun updateApiKeyDraft(value: String)

    fun loginWithChatGpt()

    fun loginWithApiKey()

    fun logoutAccount()

    fun cancelLogin()

    fun openDiscovery()

    fun dismissDiscovery()

    fun refreshDiscovery()

    fun connectDiscoveredServer(id: String)

    fun updateManualHost(value: String)

    fun updateManualPort(value: String)

    fun connectManualServer()

    fun dismissSshLogin()

    fun updateSshUsername(value: String)

    fun updateSshPassword(value: String)

    fun updateSshUseKey(value: Boolean)

    fun updateSshPrivateKey(value: String)

    fun updateSshPassphrase(value: String)

    fun updateSshRememberCredentials(value: Boolean)

    fun forgetSshCredentials()

    fun connectSshServer()

    fun removeServer(serverId: String)

    fun clearUiError()
}

class DefaultLitterAppState(
    private val serverManager: ServerManager,
    private val discoveryService: ServerDiscoveryService = ServerDiscoveryService(),
    private val sshSessionManager: SshSessionManager = SshSessionManager(),
    private val sshCredentialStore: SshCredentialStore? = null,
) : LitterAppState {
    private val _uiState = MutableStateFlow(UiShellState())
    override val uiState: StateFlow<UiShellState> = _uiState.asStateFlow()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val lastObservedAuthStatusByServerId = mutableMapOf<String, AuthStatus>()

    private val observerHandle: Closeable =
        serverManager.observe { backend ->
            mergeBackendState(backend)
        }

    init {
        connectAndPrime()
        scope.launch { runForegroundRefreshLoop() }
    }

    override fun close() {
        observerHandle.close()
        runCatching { runBlocking { sshSessionManager.disconnect() } }
        scope.cancel()
        serverManager.close()
    }

    override fun toggleSidebar() {
        _uiState.update { it.copy(isSidebarOpen = !it.isSidebarOpen) }
    }

    override fun dismissSidebar() {
        _uiState.update { it.copy(isSidebarOpen = false) }
    }

    override fun selectModel(modelId: String) {
        serverManager.updateModelSelection(modelId = modelId)
    }

    override fun selectReasoningEffort(effort: String) {
        serverManager.updateModelSelection(reasoningEffort = effort)
    }

    override fun selectSession(threadKey: ThreadKey) {
        val session = _uiState.value.sessions.firstOrNull { it.key == threadKey } ?: return
        serverManager.selectThread(threadKey = threadKey, cwdForLazyResume = session.cwd) { result ->
            result.onFailure { error ->
                setUiError(error.message ?: "Failed to resume session")
            }
            result.onSuccess {
                _uiState.update { it.copy(isSidebarOpen = false) }
            }
        }
    }

    override fun updateDraft(value: String) {
        _uiState.update { it.copy(draft = value) }
    }

    override fun refreshSessions() {
        serverManager.refreshSessions { result ->
            result.onFailure { error ->
                setUiError(error.message ?: "Failed to refresh sessions")
            }
        }
        serverManager.syncActiveThreadFromServer { result ->
            result.onFailure { error ->
                setUiError(error.message ?: "Failed to sync active thread")
            }
        }
    }

    override fun openNewSessionPicker() {
        val current = _uiState.value.currentCwd.trim()
        _uiState.update {
            it.copy(
                directoryPicker =
                    it.directoryPicker.copy(
                        isVisible = true,
                        currentPath = if (current.isNotEmpty()) current else it.directoryPicker.currentPath,
                        errorMessage = null,
                    ),
            )
        }

        val targetPath =
            if (current.isNotEmpty()) {
                current
            } else {
                _uiState.value.directoryPicker.currentPath.trim()
            }

        if (targetPath.isNotEmpty()) {
            loadDirectory(targetPath)
            return
        }

        serverManager.resolveHomeDirectory { result ->
            result.onFailure {
                loadDirectory("/")
            }
            result.onSuccess { home ->
                loadDirectory(home.ifBlank { "/" })
            }
        }
    }

    override fun dismissDirectoryPicker() {
        _uiState.update {
            it.copy(
                directoryPicker =
                    it.directoryPicker.copy(
                        isVisible = false,
                        errorMessage = null,
                        isLoading = false,
                    ),
            )
        }
    }

    override fun navigateDirectoryInto(entry: String) {
        val current = _uiState.value.directoryPicker.currentPath.ifBlank { "/" }
        val target =
            if (current == "/") {
                "/$entry"
            } else {
                "$current/$entry"
            }
        loadDirectory(target)
    }

    override fun navigateDirectoryUp() {
        val current = _uiState.value.directoryPicker.currentPath.ifBlank { "/" }
        if (current == "/") {
            loadDirectory("/")
            return
        }
        val trimmed = current.trimEnd('/')
        val up = trimmed.substringBeforeLast('/', "/").ifBlank { "/" }
        loadDirectory(up)
    }

    override fun confirmStartSessionFromPicker() {
        val snapshot = _uiState.value
        val cwd = snapshot.directoryPicker.currentPath.ifBlank { snapshot.currentCwd }
        val modelSelection =
            ModelSelection(
                modelId = snapshot.selectedModelId,
                reasoningEffort = snapshot.selectedReasoningEffort,
            )
        serverManager.startThread(cwd = cwd, modelSelection = modelSelection) { result ->
            result.onFailure { error ->
                setUiError(error.message ?: "Failed to start session")
            }
            result.onSuccess {
                _uiState.update {
                    it.copy(
                        isSidebarOpen = false,
                        directoryPicker = it.directoryPicker.copy(isVisible = false, errorMessage = null),
                    )
                }
                refreshSessions()
            }
        }
    }

    override fun sendDraft() {
        val snapshot = _uiState.value
        val prompt = snapshot.draft.trim()
        if (prompt.isEmpty() || snapshot.isSending) {
            return
        }

        _uiState.update { it.copy(draft = "") }

        val modelSelection =
            ModelSelection(
                modelId = snapshot.selectedModelId,
                reasoningEffort = snapshot.selectedReasoningEffort,
            )

        serverManager.sendMessage(
            text = prompt,
            cwd = snapshot.currentCwd,
            modelSelection = modelSelection,
        ) { result ->
            result.onFailure { error ->
                setUiError(error.message ?: "Failed to send message")
            }
        }
    }

    override fun interrupt() {
        serverManager.interrupt { result ->
            result.onFailure { error ->
                setUiError(error.message ?: "Failed to interrupt turn")
            }
        }
    }

    override fun openSettings() {
        _uiState.update {
            it.copy(
                showSettings = true,
                showAccount = false,
                accountOpenedFromSettings = false,
                discovery = it.discovery.copy(isVisible = false),
            )
        }
    }

    override fun dismissSettings() {
        _uiState.update { it.copy(showSettings = false, accountOpenedFromSettings = false) }
    }

    override fun openAccount() {
        _uiState.update { it.copy(showSettings = false, showAccount = true, accountOpenedFromSettings = true) }
        serverManager.refreshAccountState { result ->
            result.onFailure { error ->
                setUiError(error.message ?: "Failed to refresh account")
            }
        }
    }

    override fun dismissAccount() {
        _uiState.update { current ->
            current.copy(
                showAccount = false,
                showSettings = current.accountOpenedFromSettings,
                accountOpenedFromSettings = false,
            )
        }
    }

    override fun updateApiKeyDraft(value: String) {
        _uiState.update { it.copy(apiKeyDraft = value) }
    }

    override fun loginWithChatGpt() {
        _uiState.update { it.copy(isAuthWorking = true) }
        serverManager.loginWithChatGpt { result ->
            _uiState.update { it.copy(isAuthWorking = false) }
            result.onFailure { error ->
                setUiError(error.message ?: "ChatGPT login start failed")
            }
        }
    }

    override fun loginWithApiKey() {
        val key = _uiState.value.apiKeyDraft.trim()
        if (key.isEmpty()) {
            return
        }
        _uiState.update { it.copy(isAuthWorking = true) }
        serverManager.loginWithApiKey(key) { result ->
            _uiState.update { it.copy(isAuthWorking = false) }
            result.onFailure { error ->
                setUiError(error.message ?: "API key login failed")
            }
            result.onSuccess {
                _uiState.update { it.copy(apiKeyDraft = "") }
            }
        }
    }

    override fun logoutAccount() {
        _uiState.update { it.copy(isAuthWorking = true) }
        serverManager.logoutAccount { result ->
            _uiState.update { it.copy(isAuthWorking = false) }
            result.onFailure { error ->
                setUiError(error.message ?: "Logout failed")
            }
        }
    }

    override fun cancelLogin() {
        serverManager.cancelLogin { result ->
            result.onFailure { error ->
                setUiError(error.message ?: "Cancel login failed")
            }
        }
    }

    override fun openDiscovery() {
        _uiState.update {
            it.copy(
                discovery = it.discovery.copy(isVisible = true),
                isSidebarOpen = false,
                showSettings = false,
                showAccount = false,
                accountOpenedFromSettings = false,
                sshLogin = it.sshLogin.copy(isVisible = false, isConnecting = false, errorMessage = null),
            )
        }
        refreshDiscovery()
    }

    override fun dismissDiscovery() {
        _uiState.update {
            it.copy(
                discovery = it.discovery.copy(isVisible = false, errorMessage = null),
                sshLogin = it.sshLogin.copy(isVisible = false, isConnecting = false, errorMessage = null),
            )
        }
    }

    override fun refreshDiscovery() {
        _uiState.update {
            it.copy(
                discovery =
                    it.discovery.copy(
                        isVisible = true,
                        isLoading = true,
                        errorMessage = null,
                    ),
            )
        }

        scope.launch {
            val result = runCatching { discoveryService.discover() }
            result.onFailure { error ->
                _uiState.update {
                    it.copy(
                        discovery =
                            it.discovery.copy(
                                isVisible = true,
                                isLoading = false,
                                errorMessage = error.message ?: "Discovery failed",
                                servers = emptyList(),
                            ),
                    )
                }
            }
            result.onSuccess { servers ->
                _uiState.update {
                    it.copy(
                        discovery =
                            it.discovery.copy(
                                isVisible = true,
                                isLoading = false,
                                errorMessage = null,
                                servers = servers.map { discovered -> discovered.toUi() },
                            ),
                    )
                }
            }
        }
    }

    override fun connectDiscoveredServer(id: String) {
        val discovered = _uiState.value.discovery.servers.firstOrNull { it.id == id } ?: return

        if (!discovered.hasCodexServer) {
            openSshLoginFor(discovered)
            return
        }

        serverManager.connectServer(discovered.toServerConfig()) { result ->
            result.onFailure { error ->
                setUiError(error.message ?: "Connection failed")
            }
            result.onSuccess {
                _uiState.update {
                    it.copy(discovery = it.discovery.copy(isVisible = false, errorMessage = null))
                }
                postConnectPrime()
            }
        }
    }

    override fun updateManualHost(value: String) {
        _uiState.update {
            it.copy(
                discovery = it.discovery.copy(manualHost = value),
            )
        }
    }

    override fun updateManualPort(value: String) {
        _uiState.update {
            it.copy(
                discovery = it.discovery.copy(manualPort = value),
            )
        }
    }

    override fun connectManualServer() {
        val snapshot = _uiState.value.discovery
        val host = snapshot.manualHost.trim()
        val port = snapshot.manualPort.trim().toIntOrNull()
        if (host.isEmpty() || port == null || port <= 0) {
            setUiError("Enter a valid host and port")
            return
        }

        val server =
            ServerConfig(
                id = "manual-$host:$port",
                name = host,
                host = host,
                port = port,
                source = ServerSource.MANUAL,
                hasCodexServer = true,
            )

        serverManager.connectServer(server) { result ->
            result.onFailure { error ->
                setUiError(error.message ?: "Manual connection failed")
            }
            result.onSuccess {
                _uiState.update {
                    it.copy(
                        discovery =
                            it.discovery.copy(
                                isVisible = false,
                                errorMessage = null,
                                manualHost = "",
                                manualPort = "8390",
                            ),
                    )
                }
                postConnectPrime()
            }
        }
    }

    override fun dismissSshLogin() {
        _uiState.update {
            it.copy(
                sshLogin =
                    it.sshLogin.copy(
                        isVisible = false,
                        isConnecting = false,
                        password = "",
                        privateKey = "",
                        passphrase = "",
                        errorMessage = null,
                    ),
            )
        }
    }

    override fun updateSshUsername(value: String) {
        _uiState.update {
            it.copy(
                sshLogin =
                    it.sshLogin.copy(
                        username = value,
                        errorMessage = null,
                    ),
            )
        }
    }

    override fun updateSshPassword(value: String) {
        _uiState.update {
            it.copy(
                sshLogin =
                    it.sshLogin.copy(
                        password = value,
                        errorMessage = null,
                    ),
            )
        }
    }

    override fun updateSshUseKey(value: Boolean) {
        _uiState.update {
            it.copy(
                sshLogin =
                    it.sshLogin.copy(
                        useKey = value,
                        errorMessage = null,
                    ),
            )
        }
    }

    override fun updateSshPrivateKey(value: String) {
        _uiState.update {
            it.copy(
                sshLogin =
                    it.sshLogin.copy(
                        privateKey = value,
                        errorMessage = null,
                    ),
            )
        }
    }

    override fun updateSshPassphrase(value: String) {
        _uiState.update {
            it.copy(
                sshLogin =
                    it.sshLogin.copy(
                        passphrase = value,
                        errorMessage = null,
                    ),
            )
        }
    }

    override fun updateSshRememberCredentials(value: Boolean) {
        _uiState.update {
            it.copy(
                sshLogin =
                    it.sshLogin.copy(
                        rememberCredentials = value,
                        errorMessage = null,
                    ),
            )
        }
    }

    override fun forgetSshCredentials() {
        val snapshot = _uiState.value.sshLogin
        val host = snapshot.host.trim()
        if (host.isEmpty()) {
            return
        }
        sshCredentialStore?.delete(host, snapshot.port)
        _uiState.update {
            it.copy(
                sshLogin =
                    it.sshLogin.copy(
                        hasSavedCredentials = false,
                        rememberCredentials = false,
                        username = "",
                        password = "",
                        privateKey = "",
                        passphrase = "",
                        errorMessage = null,
                    ),
            )
        }
    }

    override fun connectSshServer() {
        val snapshot = _uiState.value.sshLogin
        val host = snapshot.host.trim()
        val username = snapshot.username.trim()

        if (host.isEmpty() || username.isEmpty()) {
            _uiState.update {
                it.copy(
                    sshLogin = it.sshLogin.copy(errorMessage = "Username and host are required"),
                )
            }
            return
        }

        if (!snapshot.useKey && snapshot.password.isEmpty()) {
            _uiState.update {
                it.copy(
                    sshLogin = it.sshLogin.copy(errorMessage = "Password is required"),
                )
            }
            return
        }

        if (snapshot.useKey && snapshot.privateKey.isEmpty()) {
            _uiState.update {
                it.copy(
                    sshLogin = it.sshLogin.copy(errorMessage = "Private key is required"),
                )
            }
            return
        }

        _uiState.update {
            it.copy(
                sshLogin = it.sshLogin.copy(isConnecting = true, errorMessage = null),
            )
        }

        scope.launch {
            val result =
                runCatching {
                    val credentials =
                        if (snapshot.useKey) {
                            SshCredentials.Key(
                                username = username,
                                privateKeyPem = snapshot.privateKey,
                                passphrase = snapshot.passphrase.ifBlank { null },
                            )
                        } else {
                            SshCredentials.Password(
                                username = username,
                                password = snapshot.password,
                            )
                        }

                    sshSessionManager.connect(
                        host = host,
                        port = snapshot.port,
                        credentials = credentials,
                    )
                    val remotePort = sshSessionManager.startRemoteServer()
                    sshSessionManager.disconnect()

                    if (snapshot.rememberCredentials) {
                        sshCredentialStore?.save(
                            host = host,
                            port = snapshot.port,
                            credential = snapshot.toSavedCredential(),
                        )
                    } else {
                        sshCredentialStore?.delete(host, snapshot.port)
                    }

                    val resolvedHost = normalizeHostForRemoteTarget(host)
                    ServerConfig(
                        id = "${snapshot.serverId ?: "ssh-$resolvedHost"}-remote-$remotePort",
                        name = snapshot.serverName.ifBlank { resolvedHost },
                        host = resolvedHost,
                        port = remotePort,
                        source = ServerSource.SSH,
                        hasCodexServer = true,
                    )
                }

            result.onFailure { error ->
                runCatching { sshSessionManager.disconnect() }
                _uiState.update {
                    it.copy(
                        sshLogin =
                            it.sshLogin.copy(
                                isConnecting = false,
                                errorMessage = error.message ?: "SSH connection failed",
                            ),
                    )
                }
            }

            result.onSuccess { resolvedServer ->
                serverManager.connectServer(resolvedServer) { connectResult ->
                    connectResult.onFailure { error ->
                        _uiState.update {
                            it.copy(
                                sshLogin =
                                    it.sshLogin.copy(
                                        isConnecting = false,
                                        errorMessage = error.message ?: "Failed to connect remote server",
                                    ),
                            )
                        }
                    }
                    connectResult.onSuccess {
                        _uiState.update {
                            it.copy(
                                discovery = it.discovery.copy(isVisible = false, errorMessage = null),
                                sshLogin = SshLoginUiState(),
                            )
                        }
                        postConnectPrime()
                    }
                }
            }
        }
    }

    override fun removeServer(serverId: String) {
        serverManager.removeServer(serverId)
        if (_uiState.value.connectedServers.size <= 1) {
            _uiState.update { it.copy(showAccount = false, showSettings = false) }
            openDiscovery()
        }
    }

    override fun clearUiError() {
        _uiState.update { it.copy(uiError = null) }
    }

    private fun connectAndPrime() {
        serverManager.reconnectSavedServers { result ->
            result.onFailure {
                openDiscovery()
            }
            result.onSuccess { connected ->
                if (connected.isEmpty()) {
                    openDiscovery()
                } else {
                    postConnectPrime()
                }
            }
        }
    }

    private fun postConnectPrime() {
        serverManager.loadModels { modelsResult ->
            modelsResult.onFailure { error ->
                setUiError(error.message ?: "Failed to load models")
            }
        }
        refreshSessions()
        serverManager.refreshAccountState { accountResult ->
            accountResult.onFailure { error ->
                setUiError(error.message ?: "Failed to refresh account")
            }
        }
    }

    private suspend fun runForegroundRefreshLoop() {
        while (scope.isActive) {
            serverManager.refreshSessions()
            serverManager.syncActiveThreadFromServer()
            delay(8_000)
        }
    }

    private fun openSshLoginFor(discovered: UiDiscoveredServer) {
        val saved = sshCredentialStore?.load(discovered.host, discovered.port)
        _uiState.update {
            it.copy(
                sshLogin =
                    SshLoginUiState(
                        isVisible = true,
                        serverId = discovered.id,
                        serverName = discovered.name,
                        host = discovered.host,
                        port = discovered.port,
                        username = saved?.username.orEmpty(),
                        password = saved?.password.orEmpty(),
                        useKey = saved?.method == SshAuthMethod.KEY,
                        privateKey = saved?.privateKey.orEmpty(),
                        passphrase = saved?.passphrase.orEmpty(),
                        rememberCredentials = saved != null,
                        hasSavedCredentials = saved != null,
                        isConnecting = false,
                        errorMessage = null,
                    ),
            )
        }
    }

    private fun loadDirectory(path: String) {
        val normalized = path.trim().ifEmpty { "/" }
        _uiState.update {
            it.copy(
                directoryPicker =
                    it.directoryPicker.copy(
                        isVisible = true,
                        currentPath = normalized,
                        isLoading = true,
                        errorMessage = null,
                        entries = emptyList(),
                    ),
            )
        }

        serverManager.listDirectories(normalized) { result ->
            result.onFailure { error ->
                _uiState.update {
                    it.copy(
                        directoryPicker =
                            it.directoryPicker.copy(
                                isVisible = true,
                                currentPath = normalized,
                                isLoading = false,
                                entries = emptyList(),
                                errorMessage = error.message ?: "Failed to list directory",
                            ),
                    )
                }
            }
            result.onSuccess { directories ->
                _uiState.update {
                    it.copy(
                        directoryPicker =
                            it.directoryPicker.copy(
                                isVisible = true,
                                currentPath = normalized,
                                isLoading = false,
                                entries = directories,
                                errorMessage = null,
                            ),
                    )
                }
            }
        }
    }

    private fun mergeBackendState(backend: AppState) {
        val activeThread = backend.activeThread
        val activeServerId = backend.activeServerId ?: backend.activeThreadKey?.serverId ?: backend.servers.firstOrNull()?.id
        val accountState = backend.activeAccount
        _uiState.update { current ->
            val shouldAutoOpenAccount =
                shouldAutoOpenAccountSheet(
                    activeServerId = activeServerId,
                    accountState = accountState,
                    connectionStatus = backend.connectionStatus,
                    previousConnectionStatus = current.connectionStatus,
                )
            current.copy(
                connectionStatus = backend.connectionStatus,
                connectionError = backend.connectionError,
                connectedServers = backend.servers,
                activeServerId = activeServerId,
                serverCount = backend.servers.size,
                models = backend.availableModels,
                selectedModelId = backend.selectedModel.modelId,
                selectedReasoningEffort = backend.selectedModel.reasoningEffort,
                sessions = backend.threads,
                activeThreadKey = backend.activeThreadKey,
                messages = activeThread?.messages ?: emptyList(),
                isSending = activeThread?.status == ThreadStatus.THINKING,
                currentCwd = backend.currentCwd,
                accountState = accountState,
                showSettings = if (shouldAutoOpenAccount) false else current.showSettings,
                showAccount = current.showAccount || shouldAutoOpenAccount,
                accountOpenedFromSettings = if (shouldAutoOpenAccount) false else current.accountOpenedFromSettings,
            )
        }
    }

    private fun shouldAutoOpenAccountSheet(
        activeServerId: String?,
        accountState: AccountState,
        connectionStatus: ServerConnectionStatus,
        previousConnectionStatus: ServerConnectionStatus,
    ): Boolean {
        val serverId = activeServerId ?: return false
        val previous = lastObservedAuthStatusByServerId[serverId]
        lastObservedAuthStatusByServerId[serverId] = accountState.status
        val justConnected =
            previousConnectionStatus != ServerConnectionStatus.READY &&
                connectionStatus == ServerConnectionStatus.READY
        return connectionStatus == ServerConnectionStatus.READY &&
            accountState.status == AuthStatus.NOT_LOGGED_IN &&
            (previous != AuthStatus.NOT_LOGGED_IN || justConnected)
    }

    private fun setUiError(message: String) {
        _uiState.update { it.copy(uiError = message) }
    }

    private fun SshLoginUiState.toSavedCredential(): SavedSshCredential =
        if (useKey) {
            SavedSshCredential(
                username = username.trim(),
                method = SshAuthMethod.KEY,
                password = null,
                privateKey = privateKey,
                passphrase = passphrase.ifBlank { null },
            )
        } else {
            SavedSshCredential(
                username = username.trim(),
                method = SshAuthMethod.PASSWORD,
                password = password,
                privateKey = null,
                passphrase = null,
            )
        }

    private fun normalizeHostForRemoteTarget(host: String): String {
        var normalized = host.trim().trim('[').trim(']').replace("%25", "%")
        if (!normalized.contains(':')) {
            val percent = normalized.indexOf('%')
            if (percent >= 0) {
                normalized = normalized.substring(0, percent)
            }
        }
        return normalized
    }

    private fun DiscoveredServer.toUi(): UiDiscoveredServer =
        UiDiscoveredServer(
            id = id,
            name = name,
            host = host,
            port = port,
            source = source,
            hasCodexServer = hasCodexServer,
        )

    private fun UiDiscoveredServer.toServerConfig(): ServerConfig =
        ServerConfig(
            id = id,
            name = name,
            host = host,
            port = port,
            source = source.toStateSource(),
            hasCodexServer = hasCodexServer,
        )

    private fun DiscoverySource.toStateSource(): ServerSource =
        when (this) {
            DiscoverySource.LOCAL -> ServerSource.LOCAL
            DiscoverySource.BONJOUR -> ServerSource.BONJOUR
            DiscoverySource.SSH -> ServerSource.SSH
            DiscoverySource.TAILSCALE -> ServerSource.TAILSCALE
            DiscoverySource.MANUAL -> ServerSource.MANUAL
            DiscoverySource.LAN -> ServerSource.REMOTE
        }
}

@Composable
fun rememberLitterAppState(
    serverManager: ServerManager,
): LitterAppState {
    val appContext = LocalContext.current.applicationContext
    val discoveryService = androidx.compose.runtime.remember(appContext) { ServerDiscoveryService(appContext) }
    val sshSessionManager = androidx.compose.runtime.remember { SshSessionManager() }
    val sshCredentialStore = androidx.compose.runtime.remember(appContext) { SshCredentialStore(appContext) }
    val appState =
        androidx.compose.runtime.remember(serverManager, discoveryService, sshSessionManager, sshCredentialStore) {
            DefaultLitterAppState(
                serverManager = serverManager,
                discoveryService = discoveryService,
                sshSessionManager = sshSessionManager,
                sshCredentialStore = sshCredentialStore,
            )
        }
    androidx.compose.runtime.DisposableEffect(appState) {
        onDispose { appState.close() }
    }
    return appState
}
