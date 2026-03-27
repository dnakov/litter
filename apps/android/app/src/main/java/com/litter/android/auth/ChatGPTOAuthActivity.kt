package com.litter.android.auth

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Bundle
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.zIndex
import androidx.lifecycle.lifecycleScope
import com.litter.android.state.ChatGPTOAuth
import com.litter.android.state.ChatGPTOAuthTokenBundle
import com.litter.android.ui.LitterAppTheme
import com.litter.android.ui.LitterTheme
import kotlinx.coroutines.launch

class ChatGPTOAuthActivity : ComponentActivity() {
    private lateinit var attempt: ChatGPTOAuth.AuthAttempt
    private var isCompleting = false

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)

        val authAttempt = parseAttempt(intent)
        if (authAttempt == null) {
            finishWithError("ChatGPT login could not start.")
            return
        }
        attempt = authAttempt

        setContent {
            LitterAppTheme {
                ChatGPTOAuthActivityScreen(
                    attempt = attempt,
                    onClose = {
                        setResult(Activity.RESULT_CANCELED)
                        finish()
                    },
                    onCallback = ::handleCallback,
                )
            }
        }
    }

    private fun handleCallback(callbackUri: Uri) {
        if (isCompleting) return
        isCompleting = true
        lifecycleScope.launch {
            try {
                val tokens = ChatGPTOAuth.completeAuthorization(
                    context = applicationContext,
                    callbackUri = callbackUri,
                    attempt = attempt,
                )
                setResult(Activity.RESULT_OK, resultIntent(tokens))
                finish()
            } catch (e: Exception) {
                finishWithError(e.localizedMessage ?: e.message ?: "ChatGPT login failed.")
            }
        }
    }

    private fun finishWithError(message: String) {
        setResult(
            Activity.RESULT_CANCELED,
            Intent().putExtra(EXTRA_ERROR, message),
        )
        finish()
    }

    private fun parseAttempt(intent: Intent?): ChatGPTOAuth.AuthAttempt? {
        intent ?: return null
        val state = intent.getStringExtra(EXTRA_STATE) ?: return null
        val codeVerifier = intent.getStringExtra(EXTRA_CODE_VERIFIER) ?: return null
        val redirectUri = intent.getStringExtra(EXTRA_REDIRECT_URI) ?: return null
        val authorizeUrl = intent.getStringExtra(EXTRA_AUTHORIZE_URL) ?: return null
        return ChatGPTOAuth.AuthAttempt(
            state = state,
            codeVerifier = codeVerifier,
            redirectUri = redirectUri,
            authorizeUrl = authorizeUrl,
        )
    }

    companion object {
        private const val EXTRA_STATE = "chatgpt_auth_state"
        private const val EXTRA_CODE_VERIFIER = "chatgpt_auth_code_verifier"
        private const val EXTRA_REDIRECT_URI = "chatgpt_auth_redirect_uri"
        private const val EXTRA_AUTHORIZE_URL = "chatgpt_auth_authorize_url"
        private const val EXTRA_ACCESS_TOKEN = "chatgpt_auth_access_token"
        private const val EXTRA_ACCOUNT_ID = "chatgpt_auth_account_id"
        private const val EXTRA_PLAN_TYPE = "chatgpt_auth_plan_type"
        const val EXTRA_ERROR = "chatgpt_auth_error"

        fun createIntent(context: Context, attempt: ChatGPTOAuth.AuthAttempt): Intent =
            Intent(context, ChatGPTOAuthActivity::class.java)
                .putExtra(EXTRA_STATE, attempt.state)
                .putExtra(EXTRA_CODE_VERIFIER, attempt.codeVerifier)
                .putExtra(EXTRA_REDIRECT_URI, attempt.redirectUri)
                .putExtra(EXTRA_AUTHORIZE_URL, attempt.authorizeUrl)

        fun parseResult(intent: Intent?): ChatGPTOAuthTokenBundle? {
            intent ?: return null
            val accessToken = intent.getStringExtra(EXTRA_ACCESS_TOKEN) ?: return null
            val accountId = intent.getStringExtra(EXTRA_ACCOUNT_ID) ?: return null
            return ChatGPTOAuthTokenBundle(
                accessToken = accessToken,
                idToken = "",
                refreshToken = null,
                accountId = accountId,
                planType = intent.getStringExtra(EXTRA_PLAN_TYPE),
            )
        }

        private fun resultIntent(tokens: ChatGPTOAuthTokenBundle): Intent =
            Intent()
                .putExtra(EXTRA_ACCESS_TOKEN, tokens.accessToken)
                .putExtra(EXTRA_ACCOUNT_ID, tokens.accountId)
                .putExtra(EXTRA_PLAN_TYPE, tokens.planType)
    }
}

@Composable
private fun ChatGPTOAuthActivityScreen(
    attempt: ChatGPTOAuth.AuthAttempt,
    onClose: () -> Unit,
    onCallback: (Uri) -> Unit,
) {
    var pageError by remember(attempt) { mutableStateOf<String?>(null) }
    var isCompleting by remember(attempt) { mutableStateOf(false) }
    var webViewRef by remember { mutableStateOf<WebView?>(null) }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(LitterTheme.background),
    ) {
        Box(
            modifier = Modifier
                .align(Alignment.TopStart)
                .fillMaxWidth()
                .statusBarsPadding()
                .background(LitterTheme.background)
                .zIndex(1f),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(56.dp)
                    .padding(horizontal = 8.dp),
            ) {
                IconButton(
                    onClick = onClose,
                    enabled = !isCompleting,
                ) {
                    Icon(
                        imageVector = Icons.Default.Close,
                        contentDescription = "Close login",
                        tint = LitterTheme.textPrimary,
                    )
                }
                Spacer(Modifier.width(4.dp))
                Text(
                    text = "ChatGPT Login",
                    color = LitterTheme.textPrimary,
                    fontSize = 16.sp,
                )
            }
        }

        pageError?.let { message ->
            Text(
                text = message,
                color = LitterTheme.danger,
                fontSize = 12.sp,
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .zIndex(1f)
                    .padding(start = 56.dp, top = 88.dp, end = 12.dp),
            )
        }

        ChatGPTOAuthWebView(
            attempt = attempt,
            modifier = Modifier
                .fillMaxSize()
                .padding(top = if (pageError == null) 112.dp else 132.dp),
            onCreated = { webViewRef = it },
            onCallback = { callbackUri ->
                if (isCompleting) return@ChatGPTOAuthWebView
                isCompleting = true
                pageError = null
                onCallback(callbackUri)
            },
            onPageError = { error ->
                if (!isCompleting) {
                    pageError = error
                }
            },
        )

        if (isCompleting) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.88f)),
            ) {
                CircularProgressIndicator(
                    modifier = Modifier.size(28.dp),
                    color = LitterTheme.accent,
                )
            }
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            webViewRef?.stopLoading()
            webViewRef?.destroy()
        }
    }
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun ChatGPTOAuthWebView(
    attempt: ChatGPTOAuth.AuthAttempt,
    modifier: Modifier = Modifier,
    onCreated: (WebView) -> Unit,
    onCallback: (Uri) -> Unit,
    onPageError: (String) -> Unit,
) {
    AndroidView(
        modifier = modifier,
        factory = { context ->
            CookieManager.getInstance().setAcceptCookie(true)

            WebView(context).apply {
                onCreated(this)
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.loadsImagesAutomatically = true
                settings.userAgentString = settings.userAgentString + " LitterAndroid/1.0"
                setBackgroundColor(android.graphics.Color.BLACK)
                webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(
                        view: WebView?,
                        request: WebResourceRequest?,
                    ): Boolean {
                        val uri = request?.url ?: return false
                        if (!ChatGPTOAuth.isCallbackUri(uri)) {
                            return false
                        }
                        onCallback(uri)
                        return true
                    }

                    override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
                        val uri = url?.let(Uri::parse) ?: return
                        if (ChatGPTOAuth.isCallbackUri(uri)) {
                            onCallback(uri)
                        }
                    }

                    override fun onReceivedError(
                        view: WebView?,
                        request: WebResourceRequest?,
                        error: android.webkit.WebResourceError?,
                    ) {
                        val failingUrl = request?.url?.toString().orEmpty()
                        if (request?.isForMainFrame == true &&
                            failingUrl != "about:blank" &&
                            !failingUrl.startsWith("data:")
                        ) {
                            onPageError(error?.description?.toString() ?: "ChatGPT login failed to load.")
                        }
                    }
                }
                loadUrl(attempt.authorizeUrl)
            }
        },
        update = { webView ->
            if (webView.url.isNullOrBlank()) {
                webView.loadUrl(attempt.authorizeUrl)
            }
        },
    )
}
