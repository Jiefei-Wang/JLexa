package com.example.local_ai_app

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.annotation.Keep
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

@Keep
class LlamaBridge(private val context: Context? = null) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private var activePfd: ParcelFileDescriptor? = null

    companion object {
        var isLibraryAvailable: Boolean = false
            private set

        init {
            try {
                System.loadLibrary("jlexa_native")
                isLibraryAvailable = true
            } catch (e: Throwable) {
                isLibraryAvailable = false
                e.printStackTrace()
            }
        }
    }

    private external fun nativeGetAvailableBackends(): List<Map<String, Any>>
    private external fun nativeGetActiveBackendInfo(): Map<String, Any>?
    private external fun nativeLoadModel(
        modelPath: String,
        backend: String,
        contextLength: Int,
        threads: Int,
        gpuLayers: Int,
        batchSize: Int,
        ubatchSize: Int,
        flashAttention: Int
    ): Boolean
    private external fun nativeUnloadModel()
    private external fun nativeIsModelLoaded(): Boolean
    private external fun nativeGenerate(
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        seed: Int,
        chatRoles: Array<String>?,
        chatContents: Array<String>?,
        callback: NativeGenerationCallback
    )
    private external fun nativeCancel()
    private external fun nativeResetCancellation()

    private val job = SupervisorJob()
    private val scope = CoroutineScope(job + Dispatchers.IO)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    private val pendingEvents = mutableListOf<Map<String, Any>>()
    private val isGenerating = AtomicBoolean(false)
    private var activeRequestId: String? = null

    // Native token & completion callback interface
    @Keep
    interface NativeGenerationCallback {
        @Keep
        fun onToken(token: String)
        @Keep
        fun onComplete(cancelled: Boolean, errorMsg: String)
    }

    @Keep
    class GenerationCallback(
        private val bridge: LlamaBridge,
        private val requestId: String
    ) : NativeGenerationCallback {
        override fun onToken(token: String) {
            bridge.sendEvent(
                mapOf(
                    "requestId" to requestId,
                    "type" to "token",
                    "text" to token
                )
            )
        }

        override fun onComplete(cancelled: Boolean, errorMsg: String) {
            bridge.isGenerating.set(false)
            if (bridge.activeRequestId == requestId) {
                bridge.activeRequestId = null
            }
            if (cancelled) {
                bridge.sendEvent(
                    mapOf(
                        "requestId" to requestId,
                        "type" to "cancelled"
                    )
                )
            } else if (errorMsg.isNotEmpty()) {
                bridge.sendEvent(
                    mapOf(
                        "requestId" to requestId,
                        "type" to "error",
                        "message" to errorMsg
                    )
                )
            } else {
                bridge.sendEvent(
                    mapOf(
                        "requestId" to requestId,
                        "type" to "done"
                    )
                )
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        if (events != null) {
            synchronized(pendingEvents) {
                for (ev in pendingEvents) {
                    events.success(ev)
                }
                pendingEvents.clear()
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun sendEvent(event: Map<String, Any>) {
        mainHandler.post {
            val sink = eventSink
            if (sink != null) {
                sink.success(event)
            } else {
                synchronized(pendingEvents) {
                    pendingEvents.add(event)
                }
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (!isLibraryAvailable) {
            result.error("NATIVE_LIBRARY_UNAVAILABLE", "Native library libjlexa_native.so failed to load", null)
            return
        }

        when (call.method) {
            "getAvailableBackends" -> {
                try {
                    val backends = nativeGetAvailableBackends()
                    result.success(backends)
                } catch (e: Throwable) {
                    result.error("BACKEND_DISCOVERY_ERROR", e.message, null)
                }
            }

            "getActiveBackendInfo" -> {
                try {
                    val info = nativeGetActiveBackendInfo()
                    result.success(info)
                } catch (e: Throwable) {
                    result.error("BACKEND_INFO_ERROR", e.message, null)
                }
            }

            "loadModel" -> {
                val modelPath = call.argument<String>("modelPath")
                val backend = call.argument<String>("backend") ?: "auto"
                val contextLength = call.argument<Int>("contextLength") ?: 2048
                val threads = call.argument<Int>("threads") ?: 4
                val gpuLayers = call.argument<Int>("gpuLayers") ?: -1
                val batchSize = call.argument<Int>("batchSize") ?: 512
                val ubatchSize = call.argument<Int>("ubatchSize") ?: 512
                val flashAttention = call.argument<Int>("flashAttention") ?: -1

                if (modelPath == null) {
                    result.error("INVALID_ARGS", "modelPath is required", null)
                    return
                }

                scope.launch {
                    var newPfd: ParcelFileDescriptor? = null
                    try {
                        val effectivePath = if (modelPath.startsWith("content://") && context != null) {
                            val uri = Uri.parse(modelPath)
                            val pfd = context.contentResolver.openFileDescriptor(uri, "r")
                                ?: throw IllegalStateException("Could not open file descriptor for $modelPath")
                            newPfd = pfd
                            "/proc/self/fd/${pfd.fd}"
                        } else {
                            modelPath
                        }

                        val loaded = nativeLoadModel(
                            effectivePath,
                            backend,
                            contextLength,
                            threads,
                            gpuLayers,
                            batchSize,
                            ubatchSize,
                            flashAttention
                        )

                        if (loaded) {
                            try {
                                activePfd?.close()
                            } catch (_: Throwable) {}
                            activePfd = newPfd
                        } else {
                            try {
                                newPfd?.close()
                            } catch (_: Throwable) {}
                        }

                        withContext(Dispatchers.Main) {
                            result.success(loaded)
                        }
                    } catch (e: Throwable) {
                        try {
                            newPfd?.close()
                        } catch (_: Throwable) {}
                        withContext(Dispatchers.Main) {
                            result.error("LOAD_ERROR", e.message, null)
                        }
                    }
                }
            }

            "unloadModel" -> {
                scope.launch {
                    try {
                        nativeUnloadModel()
                        try {
                            activePfd?.close()
                        } catch (_: Throwable) {}
                        activePfd = null
                        withContext(Dispatchers.Main) {
                            result.success(null)
                        }
                    } catch (e: Throwable) {
                        try {
                            activePfd?.close()
                        } catch (_: Throwable) {}
                        activePfd = null
                        withContext(Dispatchers.Main) {
                            result.error("UNLOAD_ERROR", e.message, null)
                        }
                    }
                }
            }

            "isModelLoaded" -> {
                try {
                    result.success(nativeIsModelLoaded())
                } catch (e: Throwable) {
                    result.error("STATUS_ERROR", e.message, null)
                }
            }

            "startGeneration" -> {
                val requestId = call.argument<String>("requestId") ?: UUID.randomUUID().toString()
                val prompt = call.argument<String>("prompt") ?: ""
                val maxTokens = call.argument<Int>("maxTokens") ?: 512
                val temperature = (call.argument<Double>("temperature") ?: 0.7).toFloat()
                val topP = (call.argument<Double>("topP") ?: 0.9).toFloat()
                val seed = call.argument<Int>("seed") ?: 0

                val rolesList = call.argument<List<String>>("chatRoles")
                val contentsList = call.argument<List<String>>("chatContents")
                val chatRoles = rolesList?.toTypedArray()
                val chatContents = contentsList?.toTypedArray()

                if (!isGenerating.compareAndSet(false, true)) {
                    result.error("BUSY", "Another generation is already in progress", null)
                    return
                }

                activeRequestId = requestId
                nativeResetCancellation()
                result.success(null)

                scope.launch {
                    try {
                        nativeGenerate(
                            prompt,
                            maxTokens,
                            temperature,
                            topP,
                            seed,
                            chatRoles,
                            chatContents,
                            GenerationCallback(this@LlamaBridge, requestId)
                        )
                    } catch (e: Throwable) {
                        isGenerating.set(false)
                        if (activeRequestId == requestId) {
                            activeRequestId = null
                        }
                        sendEvent(
                            mapOf(
                                "requestId" to requestId,
                                "type" to "error",
                                "message" to (e.message ?: "Generation exception")
                            )
                        )
                    }
                }
            }

            "cancelGeneration" -> {
                val reqId = call.argument<String>("requestId")
                if (reqId == null || reqId == activeRequestId) {
                    try {
                        nativeCancel()
                    } catch (_: Throwable) {}
                }
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    fun cleanUp() {
        try {
            nativeCancel()
            nativeUnloadModel()
        } catch (_: Throwable) {}
        try {
            activePfd?.close()
            activePfd = null
        } catch (_: Throwable) {}
        isGenerating.set(false)
        activeRequestId = null
        job.cancel()
        eventSink = null
    }
}

