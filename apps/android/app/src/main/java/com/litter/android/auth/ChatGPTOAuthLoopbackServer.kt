package com.litter.android.auth

import android.net.Uri
import com.litter.android.state.ChatGPTOAuthException
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.net.URI
import kotlinx.coroutines.CancellationException

internal class ChatGPTOAuthLoopbackServer private constructor(
    private val redirectUri: Uri,
    private val serverSocket: ServerSocket,
    private val appReturnUri: Uri,
) : AutoCloseable {
    fun awaitCallback(): Uri {
        val socket = try {
            serverSocket.accept()
        } catch (error: SocketException) {
            throw CancellationException("ChatGPT login loopback server closed.", error)
        }
        socket.use { client ->
            val requestTarget = readRequestTarget(client)
                ?: throw ChatGPTOAuthException("ChatGPT login callback was malformed.")
            val callbackUri = callbackUriForRequest(redirectUri, requestTarget)
            writeHtmlResponse(
                client = client,
                statusLine = "HTTP/1.1 200 OK",
                body = successHtml(appReturnUri.toString()),
            )
            return callbackUri
        }
    }

    override fun close() {
        runCatching { serverSocket.close() }
    }

    companion object {
        fun create(
            redirectUri: String,
            appReturnUri: Uri,
        ): ChatGPTOAuthLoopbackServer {
            val parsedRedirect = Uri.parse(redirectUri)
            val host = parsedRedirect.host?.takeIf { it.isNotBlank() }
                ?: throw ChatGPTOAuthException("ChatGPT login redirect URI is missing a host.")
            val port = parsedRedirect.port.takeIf { it > 0 }
                ?: throw ChatGPTOAuthException("ChatGPT login redirect URI is missing a port.")

            val socket = ServerSocket().apply {
                reuseAddress = true
                bind(
                    InetSocketAddress(
                        InetAddress.getByName(
                            if (host.equals("localhost", ignoreCase = true)) {
                                "127.0.0.1"
                            } else {
                                host
                            },
                        ),
                        port,
                    ),
                    1,
                )
            }

            return ChatGPTOAuthLoopbackServer(
                redirectUri = parsedRedirect,
                serverSocket = socket,
                appReturnUri = appReturnUri,
            )
        }

        internal fun requestTargetFromLine(requestLine: String): String? {
            val parts = requestLine.trim().split(' ')
            if (parts.size < 2) return null
            if (!parts[0].equals("GET", ignoreCase = true)) return null
            return parts[1].takeIf { it.isNotBlank() }
        }

        internal fun callbackUriForRequest(redirectUri: Uri, requestTarget: String): Uri {
            return Uri.parse(callbackUriStringForRequest(redirectUri.toString(), requestTarget))
        }

        internal fun callbackUriStringForRequest(redirectUri: String, requestTarget: String): String {
            val base = URI.create(redirectUri.toString())
            val target = URI.create(requestTarget)
            val resolved = URI(
                base.scheme,
                base.userInfo,
                base.host,
                base.port,
                target.path ?: base.path,
                target.rawQuery,
                target.rawFragment,
            )
            return resolved.toString()
        }

        internal fun successHtml(appReturnUri: String): String = """
            <!doctype html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <title>Litter Login Complete</title>
              <meta http-equiv="refresh" content="0;url=$appReturnUri">
              <style>
                body {
                  margin: 0;
                  font-family: sans-serif;
                  background: #0b0b0b;
                  color: #f2f2f2;
                  display: flex;
                  align-items: center;
                  justify-content: center;
                  min-height: 100vh;
                  padding: 24px;
                }
                main {
                  max-width: 420px;
                  line-height: 1.5;
                }
                h1 {
                  font-size: 24px;
                  margin: 0 0 12px 0;
                }
                p {
                  color: #c7c7c7;
                  margin: 0;
                }
                a {
                  color: #00ff9c;
                }
              </style>
              <script>
                window.location.replace("$appReturnUri");
              </script>
            </head>
            <body>
              <main>
                <h1>Login complete</h1>
                <p>Returning to Litter. If nothing happens, <a href="$appReturnUri">tap here</a>.</p>
              </main>
            </body>
            </html>
        """.trimIndent()

        private fun readRequestTarget(client: Socket): String? {
            val reader = BufferedReader(InputStreamReader(client.getInputStream(), Charsets.UTF_8))
            val requestLine = reader.readLine() ?: return null
            while (true) {
                val line = reader.readLine() ?: break
                if (line.isBlank()) break
            }
            return requestTargetFromLine(requestLine)
        }

        private fun writeHtmlResponse(
            client: Socket,
            statusLine: String,
            body: String,
        ) {
            val bytes = body.toByteArray(Charsets.UTF_8)
            OutputStreamWriter(client.getOutputStream(), Charsets.UTF_8).use { writer ->
                writer.appendLine(statusLine)
                writer.appendLine("Content-Type: text/html; charset=utf-8")
                writer.appendLine("Content-Length: ${bytes.size}")
                writer.appendLine("Connection: close")
                writer.appendLine()
                writer.append(body)
                writer.flush()
            }
        }
    }
}
