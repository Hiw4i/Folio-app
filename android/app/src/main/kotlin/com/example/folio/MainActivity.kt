package com.example.folio

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.res.AssetFileDescriptor
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.provider.Settings
import android.system.Os
import android.system.OsConstants
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.attribute.BasicFileAttributes
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private companion object {
        const val STORAGE_CHANNEL = "folio/storage"
        const val INTENTS_CHANNEL = "folio/intents"
        const val OFFICE_CHANNEL = "folio/office"
        const val OFFICE_VIEW_TYPE = "folio/office_view"
        const val DOCUMENT_ACCESS_REQUEST = 6107
    }

    private var eventSink: EventChannel.EventSink? = null
    private val queuedIncoming = mutableListOf<Map<String, Any?>>()
    private var initialIntent: Intent? = null
    private var initialIntentConsumed = false
    private var documentAccessResult: MethodChannel.Result? = null
    private val pdfSessions = ConcurrentHashMap<String, PdfSourceSession>()
    private val documentIoExecutor = Executors.newFixedThreadPool(2) { task ->
        Thread(task, "folio-document-io").apply { isDaemon = true }
    }
    private lateinit var officeDocuments: OfficeDocumentManager

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Keep the cold-launch intent separate from onNewIntent's setIntent.
        // A warm intent arriving during startup must not replace the document
        // the probe is about to claim, and it must not be delivered twice.
        if (initialIntent == null) initialIntent = intent
        officeDocuments = OfficeDocumentManager(this, documentIoExecutor)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, OFFICE_CHANNEL)
            .setMethodCallHandler(officeDocuments::handle)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            OFFICE_VIEW_TYPE,
            OfficePlatformViewFactory(
                flutterEngine.dartExecutor.binaryMessenger,
                officeDocuments,
            ),
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STORAGE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAccessState" -> result.success(Environment.isExternalStorageManager())
                    "openAllFilesSettings" -> {
                        openAllFilesSettings()
                        result.success(null)
                    }
                    "getStorageRoots" -> result.success(storageRoots())
                    "readContentUri" -> {
                        val rawUri = call.argument<String>("uri")
                        if (rawUri.isNullOrBlank()) {
                            result.error("invalid_uri", "The content URI is missing.", null)
                        } else {
                            readContentUri(rawUri, result)
                        }
                    }
                    "preparePdfSource" -> {
                        val rawUri = call.argument<String>("uri")
                        if (rawUri.isNullOrBlank()) {
                            result.error("invalid_uri", "The content URI is missing.", null)
                        } else {
                            preparePdfSource(rawUri, result)
                        }
                    }
                    "readPdfRange" -> {
                        val sessionId = call.argument<String>("sessionId")
                        val position = call.argument<Number>("position")?.toLong()
                        val size = call.argument<Number>("size")?.toInt()
                        if (sessionId == null || position == null || size == null) {
                            result.error("invalid_range", "The PDF range is incomplete.", null)
                        } else {
                            readPdfRange(sessionId, position, size, result)
                        }
                    }
                    "closePdfSource" -> {
                        val sessionId = call.argument<String>("sessionId")
                        if (sessionId != null) {
                            pdfSessions.remove(sessionId)?.close()
                        }
                        result.success(null)
                    }
                    "consumeInitialDocument" -> {
                        if (initialIntentConsumed) {
                            result.success(null)
                        } else {
                            initialIntentConsumed = true
                            result.success(documentFromIntent(initialIntent))
                        }
                    }
                    "requestDocumentAccess" -> {
                        if (documentAccessResult != null) {
                            result.error(
                                "picker_active",
                                "A document access request is already active.",
                                null,
                            )
                        } else {
                            documentAccessResult = result
                            val mimeType = call.argument<String>("mimeType") ?: "*/*"
                            val picker = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = mimeType
                                addFlags(
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
                                )
                            }
                            startActivityForResult(picker, DOCUMENT_ACCESS_REQUEST)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, INTENTS_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    eventSink = events
                    while (queuedIncoming.isNotEmpty()) {
                        events.success(queuedIncoming.removeAt(0))
                    }
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })

        cleanupStalePdfFiles()
    }

    override fun onDestroy() {
        if (!isChangingConfigurations) {
            if (::officeDocuments.isInitialized) officeDocuments.closeAll()
            pdfSessions.values.forEach { it.close() }
            pdfSessions.clear()
            documentIoExecutor.shutdownNow()
        }
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val incoming = documentFromIntent(intent) ?: return
        val sink = eventSink
        if (sink != null) {
            sink.success(incoming)
        } else {
            queuedIncoming.add(incoming)
        }
    }

    @Deprecated("Deprecated in Android, retained for FlutterActivity result forwarding")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != DOCUMENT_ACCESS_REQUEST) return

        val pendingResult = documentAccessResult
        documentAccessResult = null
        if (pendingResult == null) return
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            pendingResult.success(null)
            return
        }
        pendingResult.success(documentFromUri(data.data!!, data.flags))
    }

    private fun openAllFilesSettings() {
        val packageUri = Uri.parse("package:$packageName")
        val appSettings = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, packageUri)
        try {
            startActivity(appSettings)
        } catch (_: Exception) {
            startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
        }
    }

    private fun storageRoots(): List<Map<String, Any>> {
        val manager = getSystemService(Context.STORAGE_SERVICE) as StorageManager
        return manager.storageVolumes
            .mapNotNull { volume ->
                runCatching {
                    volume.directory?.canonicalPath?.let { path ->
                        mapOf("path" to path, "isRemovable" to volume.isRemovable)
                    }
                }.getOrNull()
            }
            .distinctBy { it["path"] }
    }

    private fun documentFromIntent(sourceIntent: Intent?): Map<String, Any?>? {
        if (sourceIntent == null) return null
        val uri = when (sourceIntent.action) {
            Intent.ACTION_VIEW -> sourceIntent.data
            Intent.ACTION_SEND -> {
                sourceIntent.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri
                    ?: streamUri(sourceIntent)
            }
            else -> null
        } ?: return null
        return documentFromUri(uri, sourceIntent.flags)
    }

    private fun readContentUri(rawUri: String, result: MethodChannel.Result) {
        documentIoExecutor.execute {
            try {
                val uri = Uri.parse(rawUri)
                val bytes = contentResolver.openInputStream(uri)?.use { stream ->
                    stream.readBytes()
                } ?: throw FileNotFoundException("The provider returned no stream.")
                runOnUiThread { result.success(bytes) }
            } catch (_: SecurityException) {
                runOnUiThread {
                    result.error(
                        "access_denied",
                        "Folio no longer has permission to read this file.",
                        null,
                    )
                }
            } catch (_: FileNotFoundException) {
                runOnUiThread {
                    result.error("not_found", "The file is no longer available.", null)
                }
            } catch (_: Exception) {
                runOnUiThread {
                    result.error("read_failed", "The file could not be read.", null)
                }
            }
        }
    }

    private fun preparePdfSource(rawUri: String, result: MethodChannel.Result) {
        documentIoExecutor.execute {
            try {
                val uri = Uri.parse(rawUri)
                val asset = contentResolver.openAssetFileDescriptor(uri, "r")
                    ?: throw FileNotFoundException("The provider returned no file descriptor.")
                val descriptorLength = when {
                    asset.length >= 0 -> asset.length
                    asset.parcelFileDescriptor.statSize >= 0 -> asset.parcelFileDescriptor.statSize
                    else -> -1L
                }
                val seekable = descriptorLength > 0 && runCatching {
                    Os.lseek(asset.fileDescriptor, asset.startOffset, OsConstants.SEEK_SET)
                }.isSuccess

                if (seekable) {
                    val sessionId = UUID.randomUUID().toString()
                    val stream = FileInputStream(asset.fileDescriptor)
                    pdfSessions[sessionId] = PdfRangeSession(
                        asset = asset,
                        stream = stream,
                        channel = stream.channel,
                        startOffset = asset.startOffset,
                        length = descriptorLength,
                    )
                    runOnUiThread {
                        result.success(
                            mapOf(
                                "kind" to "range",
                                "sessionId" to sessionId,
                                "length" to descriptorLength,
                            ),
                        )
                    }
                } else {
                    asset.close()
                    val directory = pdfSessionDirectory().apply { mkdirs() }
                    val sessionId = UUID.randomUUID().toString()
                    val target = File(directory, "$sessionId.pdf")
                    contentResolver.openInputStream(uri)?.use { input ->
                        target.outputStream().buffered().use { output -> input.copyTo(output) }
                    } ?: throw FileNotFoundException("The provider returned no stream.")
                    if (target.length() <= 0) {
                        target.delete()
                        throw FileNotFoundException("The provider returned an empty PDF.")
                    }
                    pdfSessions[sessionId] = PdfTemporaryFileSession(target)
                    runOnUiThread {
                        result.success(
                            mapOf(
                                "kind" to "file",
                                "sessionId" to sessionId,
                                "path" to target.absolutePath,
                                "length" to target.length(),
                            ),
                        )
                    }
                }
            } catch (_: SecurityException) {
                runOnUiThread {
                    result.error(
                        "access_denied",
                        "Folio no longer has permission to read this file.",
                        null,
                    )
                }
            } catch (_: FileNotFoundException) {
                runOnUiThread {
                    result.error("not_found", "The file is no longer available.", null)
                }
            } catch (_: Exception) {
                runOnUiThread {
                    result.error("prepare_failed", "The PDF source could not be prepared.", null)
                }
            }
        }
    }

    private fun readPdfRange(
        sessionId: String,
        position: Long,
        requestedSize: Int,
        result: MethodChannel.Result,
    ) {
        documentIoExecutor.execute {
            val session = pdfSessions[sessionId] as? PdfRangeSession
            if (session == null) {
                runOnUiThread {
                    result.error("not_found", "The PDF session has expired.", null)
                }
                return@execute
            }
            if (position < 0 || requestedSize < 0 || position > session.length) {
                runOnUiThread {
                    result.error("invalid_range", "The requested PDF range is invalid.", null)
                }
                return@execute
            }
            try {
                val remaining = (session.length - position).coerceAtLeast(0)
                val size = minOf(requestedSize.toLong(), remaining).toInt()
                if (size == 0) {
                    runOnUiThread { result.success(ByteArray(0)) }
                    return@execute
                }
                val buffer = ByteBuffer.allocate(size)
                var totalRead = 0
                while (totalRead < size) {
                    val count = session.channel.read(
                        buffer,
                        session.startOffset + position + totalRead,
                    )
                    if (count <= 0) break
                    totalRead += count
                }
                runOnUiThread { result.success(buffer.array().copyOf(totalRead)) }
            } catch (_: Exception) {
                runOnUiThread {
                    result.error("read_failed", "The PDF range could not be read.", null)
                }
            }
        }
    }

    private fun cleanupStalePdfFiles() {
        documentIoExecutor.execute {
            pdfSessionDirectory().listFiles()?.forEach { file ->
                if (file.isFile) file.delete()
            }
        }
    }

    private fun pdfSessionDirectory() = File(cacheDir, "folio_pdf_sessions")

    @Suppress("DEPRECATION")
    private fun streamUri(sourceIntent: Intent): Uri? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            sourceIntent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            sourceIntent.getParcelableExtra(Intent.EXTRA_STREAM)
        }
    }

    private fun documentFromUri(uri: Uri, flags: Int): Map<String, Any?>? {
        var persisted = false
        if (uri.scheme == "content" &&
            flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION != 0 &&
            flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0
        ) {
            try {
                contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
                persisted = true
            } catch (_: SecurityException) {
                // Some providers advertise a persistable grant but reject taking it.
            }
        }

        if (uri.scheme == "file") {
            val path = uri.path ?: return null
            val file = File(path)
            val modifiedAt = file.lastModified()
            return mapOf(
                "sourceType" to "file",
                "value" to file.absolutePath,
                "displayName" to file.name,
                "sizeBytes" to file.length(),
                "modifiedAtMillis" to modifiedAt,
                "createdAtMillis" to fileCreationMillis(file, modifiedAt),
                "mimeType" to contentResolver.getType(uri),
                "persistedPermission" to false,
            )
        }

        var displayName = uri.lastPathSegment?.substringAfterLast('/') ?: "Untitled"
        var sizeBytes = 0L
        var modifiedAt = System.currentTimeMillis()
        try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        .takeIf { it >= 0 }
                        ?.let { displayName = cursor.getString(it) ?: displayName }
                    cursor.getColumnIndex(OpenableColumns.SIZE)
                        .takeIf { it >= 0 && !cursor.isNull(it) }
                        ?.let { sizeBytes = cursor.getLong(it) }
                    cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                        .takeIf { it >= 0 && !cursor.isNull(it) }
                        ?.let { modifiedAt = cursor.getLong(it) }
                }
            }
        } catch (_: Exception) {
            // Metadata is optional; the URI itself remains usable for this session.
        }
        return mapOf(
            "sourceType" to "uri",
            "value" to uri.toString(),
            "displayName" to displayName,
            "sizeBytes" to sizeBytes,
            "modifiedAtMillis" to modifiedAt,
            "mimeType" to contentResolver.getType(uri),
            "persistedPermission" to persisted,
        )
    }

    private fun fileCreationMillis(file: File, fallback: Long): Long {
        return runCatching {
            Files.readAttributes(
                file.toPath(),
                BasicFileAttributes::class.java,
            ).creationTime().toMillis()
        }.getOrNull() ?: fallback
    }

    private sealed interface PdfSourceSession {
        fun close()
    }

    private class PdfRangeSession(
        val asset: AssetFileDescriptor,
        val stream: FileInputStream,
        val channel: FileChannel,
        val startOffset: Long,
        val length: Long,
    ) : PdfSourceSession {
        override fun close() {
            runCatching { channel.close() }
            runCatching { stream.close() }
            runCatching { asset.close() }
        }
    }

    private class PdfTemporaryFileSession(private val file: File) : PdfSourceSession {
        override fun close() {
            file.delete()
        }
    }
}
