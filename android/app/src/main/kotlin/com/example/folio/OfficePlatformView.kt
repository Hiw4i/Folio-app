package com.example.folio

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.pm.ApplicationInfo
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Magnifier
import android.view.HapticFeedbackConstants
import kotlin.math.roundToInt
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import androidx.webkit.WebViewAssetLoader
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.json.JSONObject
import org.json.JSONTokener
import java.io.ByteArrayInputStream

internal class OfficePlatformViewFactory(
    private val messenger: BinaryMessenger,
    private val documents: OfficeDocumentManager,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val parameters = (args as? Map<*, *>) ?: emptyMap<Any, Any>()
        val sessionId = parameters["sessionId"] as? String
        val session = sessionId?.let(documents::session)
        return OfficePlatformView(context, viewId, messenger, session,
            parameters["magnifierStyle"] as? Map<*, *> ?: emptyMap<Any, Any>())
    }
}

@SuppressLint("SetJavaScriptEnabled")
internal class OfficePlatformView(
    context: Context,
    viewId: Int,
    messenger: BinaryMessenger,
    private val session: OfficeDocumentSession?,
    private val magnifierStyle: Map<*, *>,
) : PlatformView {
    private val viewContext = context
    private val channel = MethodChannel(messenger, "folio/office_view/$viewId")
    private val mainHandler = Handler(Looper.getMainLooper())
    private var disposed = false
    private var started = false
    private val webView = OfficeSelectionWebView(context, ownedSelectionHandles = true)
    private var selectionMagnifier: Magnifier? = null
    private var magnifierSourceX = Float.NaN
    private var magnifierSourceY = Float.NaN
    private val assetLoader: WebViewAssetLoader

    init {
        assetLoader = WebViewAssetLoader.Builder()
            .setDomain(WebViewAssetLoader.DEFAULT_DOMAIN)
            .addPathHandler(
                "/assets/",
                WebViewAssetLoader.AssetsPathHandler(context.applicationContext),
            )
            .addPathHandler("/document/", ActiveDocumentPathHandler(session))
            .build()

        configureWebView()
        configureChannel()

    }

    override fun getView(): WebView = webView

    override fun dispose() {
        if (disposed) return
        disposed = true
        selectionMagnifier?.dismiss()
        selectionMagnifier = null
        webView.onSelectionInteractionCancelled = null
        channel.setMethodCallHandler(null)
        webView.apply {
            finishSelectionMode()
            stopLoading()
            loadUrl("about:blank")
            clearHistory()
            removeJavascriptInterface("FolioBridge")
            removeAllViews()
            destroy()
        }
    }

    private fun configureChannel() {
        channel.setMethodCallHandler { call, result ->
            if (disposed) {
                result.error("view_closed", "The Office view is closed.", null)
                return@setMethodCallHandler
            }
            when (call.method) {
                "start" -> {
                    start()
                    result.success(null)
                }
                "search" -> {
                    val query = call.argument<String>("query") ?: ""
                    evaluate("window.FolioOffice?.search(${JSONObject.quote(query)});")
                    result.success(null)
                }
                "nextHit" -> {
                    evaluate("window.FolioOffice?.nextHit();")
                    result.success(null)
                }
                "previousHit" -> {
                    evaluate("window.FolioOffice?.previousHit();")
                    result.success(null)
                }
                "goToPosition" -> {
                    val index = call.argument<Number>("index")?.toInt() ?: 0
                    evaluate("window.FolioOffice?.goToPosition($index);")
                    result.success(null)
                }
                "goToPositionInstant" -> {
                    val index = call.argument<Number>("index")?.toInt() ?: 0
                    evaluate("window.FolioOffice?.goToPosition($index, false);")
                    result.success(null)
                }
                "copySelection" -> copySelection(result)
                "selectAll" -> {
                    evaluate("window.FolioSelection?.selectAll();")
                    result.success(null)
                }
                "clearSelection" -> {
                    evaluate("window.FolioSelection?.clear();")
                    webView.finishSelectionMode()
                    result.success(null)
                }
                "reload" -> {
                    webView.reload()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun copySelection(result: MethodChannel.Result) {
        // Read text once, on explicit Copy. It never crosses the method channel
        // or gets materialized for every handle/scroll/selectionchange event.
        webView.evaluateJavascript("window.FolioSelection?.copyText() || ''") { raw ->
            if (disposed) {
                result.error("view_closed", "The Office view is closed.", null)
                return@evaluateJavascript
            }
            try {
                val text = JSONTokener(raw ?: "null").nextValue() as? String ?: ""
                if (text.isNotEmpty()) {
                    val clipboard = viewContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    clipboard.setPrimaryClip(ClipData.newPlainText("Folio", text))
                    evaluate("window.FolioSelection?.clear();")
                    webView.finishSelectionMode()
                }
                result.success(null)
            } catch (_: Exception) {
                result.error("copy_failed", "The selected text could not be copied.", null)
            }
        }
    }

    private fun evaluate(script: String) {
        webView.evaluateJavascript(script, null)
    }

    private fun start() {
        if (started || disposed) return
        started = true
        val activeSession = session
        if (activeSession == null) {
            emit(
                mapOf(
                    "type" to "error",
                    "message" to "The Office document session has expired.",
                    "recoverable" to true,
                ),
            )
            return
        }
        val url = Uri.Builder()
            .scheme("https")
            .authority(WebViewAssetLoader.DEFAULT_DOMAIN)
            .appendPath("assets")
            .appendPath("office")
            .appendPath("${activeSession.format.wireName}.html")
            .appendQueryParameter("format", activeSession.format.wireName)
            .build()
        webView.loadUrl(url.toString())
    }

    private fun emit(event: Map<String, Any?>) {
        // WebView.post() defers its runnables until the view is attached to a
        // window. The reader intentionally keeps this view un-displayed until
        // the first `ready` event arrives, so posting through the WebView
        // would deadlock the handshake. Method-channel events only need the
        // main thread, not window attachment.
        mainHandler.post {
            if (!disposed) channel.invokeMethod("event", event)
        }
    }

    private fun emitJson(raw: String) {
        runCatching {
            val json = JSONObject(raw)
            if (json.optString("type") == "selectionHaptic") {
                mainHandler.post {
                    if (!disposed && webView.hasWindowFocus()) {
                        webView.performHapticFeedback(HapticFeedbackConstants.TEXT_HANDLE_MOVE)
                    }
                }
                return
            }
            if (json.optString("type") == "selectionHandle") {
                updateSelectionMagnifier(json)
                return
            }
            val event = mutableMapOf<String, Any?>()
            json.keys().forEach { key ->
                val value = json.opt(key)
                event[key] = if (value == JSONObject.NULL) {
                    null
                } else if (value is Boolean || value is Number || value is String) {
                    value
                } else {
                    value?.toString()
                }
            }
            emit(event)
        }
    }

    private fun styleValue(name: String, fallback: Double, minimum: Double, maximum: Double): Double {
        val value = (magnifierStyle[name] as? Number)?.toDouble() ?: return fallback
        return if (value.isFinite()) value.coerceIn(minimum, maximum) else fallback
    }

    private fun updateSelectionMagnifier(event: JSONObject) {
        // Owned DOM handles use the platform magnifier's public API. Only
        // normalized source coordinates cross this bridge, never selected text.
        val active = event.optBoolean("active")
        val x = event.optDouble("x", Double.NaN)
        val y = event.optDouble("y", Double.NaN)
        mainHandler.post {
            if (disposed) return@post
            if (!active || !x.isFinite() || !y.isFinite() || !webView.isAttachedToWindow
                || !webView.hasWindowFocus()) {
                selectionMagnifier?.dismiss()
                selectionMagnifier = null
                return@post
            }
            val magnifier = selectionMagnifier ?: Magnifier.Builder(webView)
                .setSize(styleValue("width", 77.37, 1.0, 200.0).times(webView.resources.displayMetrics.density).roundToInt(),
                    styleValue("height", 37.9, 1.0, 100.0).times(webView.resources.displayMetrics.density).roundToInt())
                .setCornerRadius(styleValue("cornerRadius", 40.0, 0.0, 100.0).toFloat() * webView.resources.displayMetrics.density)
                .setInitialZoom(styleValue("zoom", 1.25, 1.0, 4.0).toFloat())
                .setOverlay(android.graphics.drawable.ColorDrawable(Color.argb(8, 158, 158, 158)))
                .build().also {
                selectionMagnifier = it
                magnifierSourceX = Float.NaN
                magnifierSourceY = Float.NaN
            }
            val sourceX = (x.coerceIn(0.0, 1.0) * webView.width).toFloat()
            val sourceY = (y.coerceIn(0.0, 1.0) * webView.height).toFloat()
            if (sourceX == magnifierSourceX && sourceY == magnifierSourceY) {
                magnifier.update()
            } else {
                magnifier.show(sourceX, sourceY)
                magnifierSourceX = sourceX
                magnifierSourceY = sourceY
            }
        }
    }

    private fun blockedResponse(): WebResourceResponse = WebResourceResponse(
        "text/plain",
        "utf-8",
        403,
        "Blocked",
        mapOf("Cache-Control" to "no-store"),
        ByteArrayInputStream(ByteArray(0)),
    )

    private fun configureWebView() {
        webView.onSelectionInteractionCancelled = {
            selectionMagnifier?.dismiss()
            selectionMagnifier = null
            if (!disposed) evaluate("window.FolioSelection?.cancelDrag();")
        }
        // The Android selection magnifier samples the WebView's own surface.
        // An opaque backing prevents a black loupe around transparent pages.
        webView.setBackgroundColor(Color.rgb(11, 12, 14))
        // Only our shared spring should provide edge feedback (no Android glow/stretch).
        webView.overScrollMode = WebView.OVER_SCROLL_NEVER
        // No position indicator bars on the screen edges: navigation is
        // page-by-page, and CSS already hides webkit scrollbars inside.
        webView.isVerticalScrollBarEnabled = false
        webView.isHorizontalScrollBarEnabled = false
        // Authored page/slide colours must not be recoloured by Force Dark.
        // This is the document WebView only; Folio's dark UI stays unchanged.
        webView.isForceDarkAllowed = false
        if (WebViewFeature.isFeatureSupported(WebViewFeature.ALGORITHMIC_DARKENING)) {
            WebSettingsCompat.setAlgorithmicDarkeningAllowed(webView.settings, false)
        }
        // Let WebView choose its compositor. Forcing a separate hardware layer
        // can leave Chromium's native selection magnifier with a black capture.
        webView.setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_BOUND, true)
        WebView.setWebContentsDebuggingEnabled(
            viewContext.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0,
        )
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, false)
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = false
            cacheMode = WebSettings.LOAD_NO_CACHE
            allowFileAccess = false
            allowContentAccess = false
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            mediaPlaybackRequiresUserGesture = true
            builtInZoomControls = true
            displayZoomControls = false
            setSupportZoom(true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                safeBrowsingEnabled = true
            }
        }
        webView.removeJavascriptInterface("searchBoxJavaBridge_")
        webView.removeJavascriptInterface("accessibility")
        webView.removeJavascriptInterface("accessibilityTraversal")
        webView.addJavascriptInterface(
            object {
                @JavascriptInterface
                fun postMessage(message: String) = emitJson(message)
            },
            "FolioBridge",
        )
        webView.setDownloadListener { _, _, _, _, _ ->
            emit(
                mapOf(
                    "type" to "blocked",
                    "message" to "Downloads are disabled in documents.",
                ),
            )
        }
        webView.webChromeClient = object : WebChromeClient() {
            override fun onCreateWindow(
                view: WebView?,
                isDialog: Boolean,
                isUserGesture: Boolean,
                resultMsg: android.os.Message?,
            ): Boolean = false
        }
        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(
                view: WebView?,
                request: WebResourceRequest?,
            ): Boolean = true

            override fun shouldInterceptRequest(
                view: WebView?,
                request: WebResourceRequest?,
            ): WebResourceResponse? {
                val uri = request?.url ?: return blockedResponse()
                if (uri.scheme != "https" || uri.host != WebViewAssetLoader.DEFAULT_DOMAIN) {
                    return blockedResponse()
                }
                return assetLoader.shouldInterceptRequest(uri) ?: blockedResponse()
            }

            // A failed main-frame load (missing page, asset failure)
            // would otherwise leave the reader on "Opening document..."
            // forever: the JS boot never runs, so no ready/error is posted.
            // Sub-frame/resource blocks (fonts, images) are ignored — the
            // document itself can still render.
            override fun onReceivedError(
                view: WebView?,
                request: WebResourceRequest?,
                error: WebResourceError?,
            ) {
                if (request?.isForMainFrame == true) {
                    emit(
                        mapOf(
                            "type" to "error",
                            "message" to "The Office document could not be displayed.",
                            "recoverable" to true,
                        ),
                    )
                }
            }

            override fun onReceivedHttpError(
                view: WebView?,
                request: WebResourceRequest?,
                errorResponse: WebResourceResponse?,
            ) {
                if (request?.isForMainFrame == true) {
                    emit(
                        mapOf(
                            "type" to "error",
                            "message" to "The Office document could not be displayed.",
                            "recoverable" to true,
                        ),
                    )
                }
            }

            override fun onRenderProcessGone(
                view: WebView?,
                detail: RenderProcessGoneDetail?,
            ): Boolean {
                channel.invokeMethod(
                    "event",
                    mapOf(
                        "type" to "error",
                        "message" to if (detail?.didCrash() == true) {
                            "The Office renderer stopped unexpectedly."
                        } else {
                            "Android reclaimed the Office renderer."
                        },
                        "recoverable" to true,
                    ),
                )
                if (!disposed) {
                    disposed = true
                    selectionMagnifier?.dismiss()
                    selectionMagnifier = null
                    webView.onSelectionInteractionCancelled = null
                    channel.setMethodCallHandler(null)
                    webView.removeJavascriptInterface("FolioBridge")
                    webView.removeAllViews()
                    webView.destroy()
                }
                return true
            }
        }
    }

    private class ActiveDocumentPathHandler(
        private val session: OfficeDocumentSession?,
    ) : WebViewAssetLoader.PathHandler {
        override fun handle(path: String): WebResourceResponse {
            if (path != "active" || session == null) {
                return WebResourceResponse(
                    "text/plain",
                    "utf-8",
                    404,
                    "Not found",
                    mapOf("Cache-Control" to "no-store"),
                    ByteArrayInputStream(ByteArray(0)),
                )
            }
            return try {
                WebResourceResponse(
                    session.format.mimeType,
                    null,
                    200,
                    "OK",
                    mapOf(
                        "Cache-Control" to "no-store",
                        "Content-Security-Policy" to "default-src 'none'",
                        "X-Content-Type-Options" to "nosniff",
                    ),
                    session.openStream().buffered(),
                )
            } catch (_: Exception) {
                WebResourceResponse(
                    "text/plain",
                    "utf-8",
                    404,
                    "Not found",
                    mapOf("Cache-Control" to "no-store"),
                    ByteArrayInputStream(ByteArray(0)),
                )
            }
        }
    }
}
