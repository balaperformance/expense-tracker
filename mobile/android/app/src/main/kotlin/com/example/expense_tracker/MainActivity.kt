package com.example.expense_tracker

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.util.Base64
import android.util.Log
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Hosts the statement-import engine.
 *
 * Bank statements are read with the web app's own parsing code (PDF.js plus
 * the statement parsers), bundled into assets/statement_engine/engine.js. It
 * runs in a hidden system WebView — part of Android itself, so no extra
 * library — with network loads blocked: the statement never leaves the
 * phone. Dart talks to it through one method channel:
 *
 *   pickFile            system document picker → {token, name, size}
 *   call(name, args)    one engine function, JSON in and JSON out
 *   release(token)      forget a picked file
 *
 * It also hosts the push-notification bridge (PushBridge.kt): permission,
 * the FCM token and the page a tapped notification opens.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "expense_tracker/statement_engine"
    private val pickRequest = 4711
    private val main = Handler(Looper.getMainLooper())

    /** Picked files, held in memory only for the length of an import session. Read from the WebView's thread. */
    private val files = ConcurrentHashMap<String, ByteArray>()
    private val pending = HashMap<String, MethodChannel.Result>()
    private val queued = ArrayList<Runnable>()

    private var push: PushBridge? = null

    private var pickResult: MethodChannel.Result? = null
    private var webView: WebView? = null
    private var engineReady = false
    private var engineFailed: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result -> handle(call, result) }
        PushNotifications.ensureChannel(this)
        // A notification tapped while the app was closed: its page waits for Dart to ask.
        push = PushBridge(this, flutterEngine.dartExecutor.binaryMessenger).also {
            it.handleIntent(intent, running = false)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // A notification tapped while the app was open or in the background.
        push?.handleIntent(intent, running = true)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        push?.onPermissionResult(requestCode)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickFile" -> pickFile(result)
            "call" -> callEngine(
                call.argument<String>("name") ?: "",
                call.argument<String>("args") ?: "{}",
                result,
            )
            "release" -> {
                call.argument<String>("token")?.let { files.remove(it) }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ---- File picking -------------------------------------------------------

    private fun pickFile(result: MethodChannel.Result) {
        if (pickResult != null) {
            result.error("busy", "A file is already being chosen.", null)
            return
        }
        pickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf(
                    "application/pdf",
                    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                    "application/vnd.ms-excel",
                    "application/octet-stream",
                ),
            )
        }
        try {
            startActivityForResult(intent, pickRequest)
        } catch (error: Exception) {
            pickResult = null
            result.error("unavailable", "No file picker is available on this phone.", null)
        }
    }

    @Deprecated("FlutterActivity still delivers results through onActivityResult")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickRequest) return
        val result = pickResult ?: return
        pickResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        // Reading can take a moment for a cloud-backed file; keep it off the UI thread.
        Thread {
            val reply = readPicked(uri)
            main.post { result.success(reply) }
        }.start()
    }

    private fun readPicked(uri: Uri): Map<String, Any?> {
        val name = displayName(uri) ?: "statement"
        return try {
            val bytes = contentResolver.openInputStream(uri)?.use { input ->
                val out = ByteArrayOutputStream()
                val buffer = ByteArray(64 * 1024)
                var total = 0
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    total += read
                    // Matches the engine's own limit; a statement is never this big.
                    if (total > MAX_BYTES) return mapOf("error" to "tooLarge", "name" to name)
                    out.write(buffer, 0, read)
                }
                out.toByteArray()
            } ?: return mapOf("error" to "unreadable", "name" to name)
            val token = UUID.randomUUID().toString()
            files[token] = bytes
            mapOf("token" to token, "name" to name, "size" to bytes.size)
        } catch (error: Exception) {
            mapOf("error" to "unreadable", "name" to name)
        }
    }

    private fun displayName(uri: Uri): String? = try {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    } catch (error: Exception) {
        null
    }

    // ---- Engine -------------------------------------------------------------

    private fun callEngine(name: String, args: String, result: MethodChannel.Result) {
        engineFailed?.let {
            result.error("engineUnavailable", it, null)
            return
        }
        val id = UUID.randomUUID().toString()
        pending[id] = result
        val run = Runnable {
            webView?.evaluateJavascript(
                "window.__engineCall(${JSONObject.quote(id)}, ${JSONObject.quote(name)}, ${JSONObject.quote(args)});",
                null,
            )
        }
        // A large statement on a slow phone takes seconds, never minutes.
        main.postDelayed({
            pending.remove(id)?.error("timeout", "Reading the statement took too long. Try again.", null)
        }, CALL_TIMEOUT_MS)
        if (engineReady) run.run() else {
            queued.add(run)
            ensureEngine()
        }
    }

    @SuppressLint("SetJavaScriptEnabled", "JavascriptInterface")
    private fun ensureEngine() {
        if (webView != null) return
        val script = try {
            assets.open("flutter_assets/assets/statement_engine/engine.js").bufferedReader().use { it.readText() }
        } catch (error: Exception) {
            failEngine("The statement reader is missing from this build.")
            return
        }
        val view = WebView(this)
        view.settings.javaScriptEnabled = true
        // Offline by construction: the engine needs nothing from the network or the file system.
        view.settings.blockNetworkLoads = true
        view.settings.allowFileAccess = false
        view.settings.allowContentAccess = false
        view.addJavascriptInterface(Bridge(), "EngineBridge")
        view.webChromeClient = object : WebChromeClient() {
            override fun onConsoleMessage(message: ConsoleMessage): Boolean {
                if (message.messageLevel() == ConsoleMessage.MessageLevel.ERROR) {
                    Log.w("StatementEngine", message.message())
                }
                return true
            }
        }
        view.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = true

            override fun onPageFinished(view: WebView, url: String?) {
                view.evaluateJavascript("typeof window.__engineCall === 'function'") { ready ->
                    if (ready == "true") {
                        engineReady = true
                        val runs = ArrayList(queued)
                        queued.clear()
                        runs.forEach { it.run() }
                    } else {
                        failEngine(
                            "This phone's Android System WebView is too old to read statements. " +
                                "Update it from the Play Store, then try again.",
                        )
                    }
                }
            }
        }
        webView = view
        // An https base gives the page a secure context (needed for hashing) without loading anything.
        view.loadDataWithBaseURL(
            "https://statement-engine.invalid/",
            "<!doctype html><meta charset=\"utf-8\"><script>${script.replace("</script", "<\\/script")}</script>",
            "text/html",
            "utf-8",
            null,
        )
    }

    private fun failEngine(message: String) {
        engineFailed = message
        queued.clear()
        val waiting = HashMap(pending)
        pending.clear()
        waiting.values.forEach { it.error("engineUnavailable", message, null) }
    }

    /** What the engine may call back into. Runs on a WebView thread; replies hop to the main thread. */
    private inner class Bridge {
        @JavascriptInterface
        fun result(id: String, json: String) {
            main.post { pending.remove(id)?.success(json) }
        }

        @JavascriptInterface
        fun fileSize(token: String): Int = files[token]?.size ?: -1

        @JavascriptInterface
        fun readChunk(token: String, index: Int): String {
            val bytes = files[token] ?: return ""
            val start = index.toLong() * CHUNK_BYTES
            if (start >= bytes.size) return ""
            val end = minOf(bytes.size.toLong(), start + CHUNK_BYTES).toInt()
            return Base64.encodeToString(bytes, start.toInt(), end - start.toInt(), Base64.NO_WRAP)
        }
    }

    override fun onDestroy() {
        webView?.destroy()
        webView = null
        files.clear()
        super.onDestroy()
    }

    private companion object {
        const val MAX_BYTES = 20 * 1024 * 1024
        const val CHUNK_BYTES = 512 * 1024
        const val CALL_TIMEOUT_MS = 120_000L
    }
}
