package com.example.local_ai_app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.annotation.Keep
import androidx.documentfile.provider.DocumentFile
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap

@Keep
class SafStorageBridge(private val context: Context) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val REQUEST_CODE_SAF = 9021
        private const val PREFS_NAME = "jlexa_saf_prefs"
        private const val KEY_BASE_TREE_URI = "base_tree_uri"
    }

    private val job = SupervisorJob()
    private val scope = CoroutineScope(job + Dispatchers.IO)
    private val mainHandler = Handler(Looper.getMainLooper())

    private var downloadEventSink: EventChannel.EventSink? = null
    private var pendingPickerResult: MethodChannel.Result? = null
    private val activeDownloads = ConcurrentHashMap<String, HttpURLConnection>()
    private val cancelledRequests = Collections.newSetFromMap(ConcurrentHashMap<String, Boolean>())

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        downloadEventSink = events
    }

    override fun onCancel(arguments: Any?) {
        downloadEventSink = null
    }

    private fun sendDownloadEvent(event: Map<String, Any>) {
        mainHandler.post {
            downloadEventSink?.success(event)
        }
    }

    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE_SAF) return false
        val result = pendingPickerResult ?: return false
        pendingPickerResult = null

        if (resultCode == Activity.RESULT_OK && data?.data != null) {
            val treeUri = data.data!!
            try {
                val takeFlags = data.flags and (
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
                context.contentResolver.takePersistableUriPermission(treeUri, takeFlags)

                val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                prefs.edit().putString(KEY_BASE_TREE_URI, treeUri.toString()).apply()

                val rootDoc = DocumentFile.fromTreeUri(context, treeUri)
                if (rootDoc != null && rootDoc.exists()) {
                    getOrCreateDirectory(rootDoc, "llm")
                    getOrCreateDirectory(rootDoc, "whisper")
                    result.success(
                        mapOf(
                            "treeUri" to treeUri.toString(),
                            "displayName" to (rootDoc.name ?: "Models")
                        )
                    )
                } else {
                    result.success(null)
                }
            } catch (e: Throwable) {
                result.error("SAF_PERMISSION_ERROR", e.message, null)
            }
        } else {
            result.success(null)
        }
        return true
    }

    fun chooseBaseFolder(activity: Activity, result: MethodChannel.Result) {
        pendingPickerResult = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
                )
            }
            activity.startActivityForResult(intent, REQUEST_CODE_SAF)
        } catch (e: Throwable) {
            pendingPickerResult = null
            result.error("SAF_INTENT_ERROR", e.message, null)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "chooseBaseFolder" -> {
                if (context is Activity) {
                    chooseBaseFolder(context, result)
                } else {
                    result.error("NO_ACTIVITY", "SAF folder picker requires an active Activity context", null)
                }
            }

            "restorePersistedFolderAccess" -> {
                val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                val uriStr = prefs.getString(KEY_BASE_TREE_URI, null)
                if (uriStr == null) {
                    result.success(null)
                    return
                }

                try {
                    val treeUri = Uri.parse(uriStr)
                    val hasPerm = context.contentResolver.persistedUriPermissions.any {
                        it.uri == treeUri && it.isReadPermission && it.isWritePermission
                    }
                    if (!hasPerm) {
                        prefs.edit().remove(KEY_BASE_TREE_URI).apply()
                        result.success(null)
                        return
                    }

                    val rootDoc = DocumentFile.fromTreeUri(context, treeUri)
                    if (rootDoc != null && rootDoc.exists() && rootDoc.canRead() && rootDoc.canWrite()) {
                        getOrCreateDirectory(rootDoc, "llm")
                        getOrCreateDirectory(rootDoc, "whisper")
                        result.success(
                            mapOf(
                                "treeUri" to treeUri.toString(),
                                "displayName" to (rootDoc.name ?: "Models")
                            )
                        )
                    } else {
                        prefs.edit().remove(KEY_BASE_TREE_URI).apply()
                        result.success(null)
                    }
                } catch (e: Throwable) {
                    prefs.edit().remove(KEY_BASE_TREE_URI).apply()
                    result.success(null)
                }
            }

            "clearPersistedFolderAccess" -> {
                val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                val uriStr = prefs.getString(KEY_BASE_TREE_URI, null)
                if (uriStr != null) {
                    try {
                        val treeUri = Uri.parse(uriStr)
                        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                        context.contentResolver.releasePersistableUriPermission(treeUri, flags)
                    } catch (_: Throwable) {}
                    prefs.edit().remove(KEY_BASE_TREE_URI).apply()
                }
                result.success(null)
            }

            "listModelFiles" -> {
                val type = call.argument<String>("type") ?: "llm"
                scope.launch {
                    try {
                        val rootDoc = getRootDocument()
                        if (rootDoc == null) {
                            withContext(Dispatchers.Main) { result.success(emptyList<Map<String, Any>>()) }
                            return@launch
                        }

                        val subDir = rootDoc.findFile(type)
                        if (subDir == null || !subDir.exists() || !subDir.isDirectory) {
                            withContext(Dispatchers.Main) { result.success(emptyList<Map<String, Any>>()) }
                            return@launch
                        }

                        val files = subDir.listFiles()
                        val res = mutableListOf<Map<String, Any>>()
                        for (f in files) {
                            val name = f.name ?: continue
                            if (name.endsWith(".part", ignoreCase = true)) continue

                            val lower = name.lowercase()
                            val isValid = if (type == "llm") {
                                lower.endsWith(".gguf")
                            } else {
                                lower.endsWith(".bin") || lower.endsWith(".ggml") || lower.endsWith(".gguf")
                            }

                            if (isValid && f.length() > 0) {
                                res.add(
                                    mapOf(
                                        "uri" to f.uri.toString(),
                                        "name" to name,
                                        "size" to f.length(),
                                        "lastModified" to f.lastModified()
                                    )
                                )
                            }
                        }

                        withContext(Dispatchers.Main) { result.success(res) }
                    } catch (e: Throwable) {
                        withContext(Dispatchers.Main) { result.error("LIST_ERROR", e.message, null) }
                    }
                }
            }

            "prepareDownloadPart" -> {
                val type = call.argument<String>("type") ?: "llm"
                val filename = call.argument<String>("filename")
                if (filename == null) {
                    result.error("INVALID_ARGS", "filename is required", null)
                    return
                }

                scope.launch {
                    try {
                        val rootDoc = getRootDocument()
                            ?: throw IllegalStateException("Storage directory not configured")
                        val subDir = getOrCreateDirectory(rootDoc, type)
                            ?: throw IllegalStateException("Cannot create subfolder $type")

                        val partName = "$filename.part"
                        val existingPart = subDir.findFile(partName)
                        existingPart?.delete()

                        val partDoc = subDir.createFile("application/octet-stream", partName)
                            ?: throw IllegalStateException("Failed to create partial download file")

                        withContext(Dispatchers.Main) {
                            result.success(mapOf("partUri" to partDoc.uri.toString()))
                        }
                    } catch (e: Throwable) {
                        withContext(Dispatchers.Main) {
                            result.error("PREPARE_PART_ERROR", e.message, null)
                        }
                    }
                }
            }

            "downloadFile" -> {
                val urlStr = call.argument<String>("url")
                val targetUriStr = call.argument<String>("targetUri")
                val requestId = call.argument<String>("requestId")
                val expectedSizeBytes = (call.argument<Number>("expectedSizeBytes"))?.toLong() ?: 0L

                if (urlStr == null || targetUriStr == null || requestId == null) {
                    result.error("INVALID_ARGS", "url, targetUri, and requestId are required", null)
                    return
                }

                result.success(null) // Acknowledge launch of download

                scope.launch {
                    var conn: HttpURLConnection? = null
                    var inStream: InputStream? = null
                    var outStream: OutputStream? = null

                    cancelledRequests.remove(requestId)

                    try {
                        val targetUri = Uri.parse(targetUriStr)
                        val out = context.contentResolver.openOutputStream(targetUri, "wt")
                            ?: throw IllegalStateException("Cannot open output stream for $targetUriStr")
                        outStream = out

                        val url = URL(urlStr)
                        conn = (url.openConnection() as HttpURLConnection).apply {
                            connectTimeout = 30000
                            readTimeout = 60000
                            instanceFollowRedirects = true
                            requestMethod = "GET"
                        }
                        activeDownloads[requestId] = conn
                        conn.connect()

                        val code = conn.responseCode
                        if (code !in 200..299) {
                            throw IllegalStateException("Server returned HTTP $code")
                        }

                        val totalBytes = if (conn.contentLengthLong > 0) conn.contentLengthLong else expectedSizeBytes
                        inStream = conn.inputStream

                        val buffer = ByteArray(64 * 1024)
                        var bytesReceived = 0L
                        var lastProgressReportTime = 0L

                        while (true) {
                            if (cancelledRequests.contains(requestId)) {
                                sendDownloadEvent(
                                    mapOf(
                                        "requestId" to requestId,
                                        "type" to "cancelled"
                                    )
                                )
                                return@launch
                            }

                            val read = inStream.read(buffer)
                            if (read == -1) break

                            out.write(buffer, 0, read)
                            bytesReceived += read

                            val now = System.currentTimeMillis()
                            if (now - lastProgressReportTime >= 100) {
                                lastProgressReportTime = now
                                sendDownloadEvent(
                                    mapOf(
                                        "requestId" to requestId,
                                        "type" to "progress",
                                        "bytesReceived" to bytesReceived,
                                        "totalBytes" to totalBytes
                                    )
                                )
                            }
                        }

                        out.flush()

                        if (cancelledRequests.contains(requestId)) {
                            sendDownloadEvent(
                                mapOf(
                                    "requestId" to requestId,
                                    "type" to "cancelled"
                                )
                            )
                        } else {
                            sendDownloadEvent(
                                mapOf(
                                    "requestId" to requestId,
                                    "type" to "done",
                                    "bytesReceived" to bytesReceived,
                                    "totalBytes" to totalBytes
                                )
                            )
                        }
                    } catch (e: Throwable) {
                        if (cancelledRequests.contains(requestId)) {
                            sendDownloadEvent(
                                mapOf(
                                    "requestId" to requestId,
                                    "type" to "cancelled"
                                )
                            )
                        } else {
                            sendDownloadEvent(
                                mapOf(
                                    "requestId" to requestId,
                                    "type" to "error",
                                    "message" to (e.message ?: "Download failed")
                                )
                            )
                        }
                    } finally {
                        try { inStream?.close() } catch (_: Throwable) {}
                        try { outStream?.close() } catch (_: Throwable) {}
                        try { conn?.disconnect() } catch (_: Throwable) {}
                        activeDownloads.remove(requestId)
                        cancelledRequests.remove(requestId)
                    }
                }
            }

            "cancelDownload" -> {
                val requestId = call.argument<String>("requestId")
                if (requestId != null) {
                    cancelledRequests.add(requestId)
                    val conn = activeDownloads.remove(requestId)
                    try {
                        conn?.disconnect()
                    } catch (_: Throwable) {}
                }
                result.success(null)
            }

            "finalizeDownload" -> {
                val partUriStr = call.argument<String>("partUri")
                val filename = call.argument<String>("filename")
                val type = call.argument<String>("type") ?: "llm"
                val expectedSizeBytes = (call.argument<Number>("expectedSizeBytes"))?.toLong() ?: 0L

                if (partUriStr == null || filename == null) {
                    result.error("INVALID_ARGS", "partUri and filename are required", null)
                    return
                }

                scope.launch {
                    try {
                        val partDoc = DocumentFile.fromSingleUri(context, Uri.parse(partUriStr))
                        if (partDoc == null || !partDoc.exists()) {
                            throw IllegalStateException("Downloaded partial file not found")
                        }

                        val size = partDoc.length()
                        if (size == 0L) {
                            partDoc.delete()
                            throw IllegalStateException("Downloaded file is empty (0 bytes)")
                        }

                        if (expectedSizeBytes > 0L && size != expectedSizeBytes) {
                            partDoc.delete()
                            throw IllegalStateException("Size mismatch: expected $expectedSizeBytes bytes, got $size bytes")
                        }

                        val rootDoc = getRootDocument()
                            ?: throw IllegalStateException("Storage directory not configured")
                        val subDir = getOrCreateDirectory(rootDoc, type)
                            ?: throw IllegalStateException("Target folder $type not accessible")

                        val existingFinal = subDir.findFile(filename)
                        existingFinal?.delete()

                        val renamed = partDoc.renameTo(filename)
                        if (!renamed) {
                            throw IllegalStateException("Failed to rename partial download to $filename")
                        }

                        val finalFile = subDir.findFile(filename)
                        val finalUri = finalFile?.uri ?: partDoc.uri

                        withContext(Dispatchers.Main) {
                            result.success(mapOf("finalUri" to finalUri.toString()))
                        }
                    } catch (e: Throwable) {
                        withContext(Dispatchers.Main) {
                            result.error("FINALIZE_ERROR", e.message, null)
                        }
                    }
                }
            }

            "deleteModelFile" -> {
                val uriStr = call.argument<String>("uri")
                if (uriStr == null) {
                    result.error("INVALID_ARGS", "uri is required", null)
                    return
                }

                scope.launch {
                    try {
                        val doc = DocumentFile.fromSingleUri(context, Uri.parse(uriStr))
                        val deleted = doc?.delete() ?: false
                        withContext(Dispatchers.Main) { result.success(deleted) }
                    } catch (e: Throwable) {
                        withContext(Dispatchers.Main) { result.success(false) }
                    }
                }
            }

            "cleanStalePartFiles" -> {
                val activeList = call.argument<List<String>>("activeUris") ?: emptyList()
                val activeSet = activeList.toSet()

                scope.launch {
                    try {
                        val rootDoc = getRootDocument() ?: return@launch
                        for (subName in listOf("llm", "whisper")) {
                            val subDir = rootDoc.findFile(subName) ?: continue
                            for (f in subDir.listFiles()) {
                                if (f.name?.endsWith(".part", ignoreCase = true) == true) {
                                    if (!activeSet.contains(f.uri.toString())) {
                                        try { f.delete() } catch (_: Throwable) {}
                                    }
                                }
                            }
                        }
                        withContext(Dispatchers.Main) { result.success(null) }
                    } catch (_: Throwable) {
                        withContext(Dispatchers.Main) { result.success(null) }
                    }
                }
            }

            "getFileSize" -> {
                val uriStr = call.argument<String>("uri")
                if (uriStr == null) {
                    result.success(0L)
                    return
                }
                val doc = DocumentFile.fromSingleUri(context, Uri.parse(uriStr))
                result.success(doc?.length() ?: 0L)
            }

            "fileExists" -> {
                val uriStr = call.argument<String>("uri")
                if (uriStr == null) {
                    result.success(false)
                    return
                }
                val doc = DocumentFile.fromSingleUri(context, Uri.parse(uriStr))
                result.success(doc?.exists() ?: false)
            }

            else -> result.notImplemented()
        }
    }

    private fun getRootDocument(): DocumentFile? {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val uriStr = prefs.getString(KEY_BASE_TREE_URI, null) ?: return null
        val treeUri = Uri.parse(uriStr)
        val doc = DocumentFile.fromTreeUri(context, treeUri)
        return if (doc != null && doc.exists() && doc.canRead() && doc.canWrite()) doc else null
    }

    private fun getOrCreateDirectory(parent: DocumentFile, name: String): DocumentFile? {
        val existing = parent.findFile(name)
        if (existing != null && existing.exists() && existing.isDirectory) {
            return existing
        }
        return parent.createDirectory(name)
    }

    fun cleanUp() {
        for ((_, conn) in activeDownloads) {
            try { conn.disconnect() } catch (_: Throwable) {}
        }
        activeDownloads.clear()
        cancelledRequests.clear()
        job.cancel()
        downloadEventSink = null
    }
}
