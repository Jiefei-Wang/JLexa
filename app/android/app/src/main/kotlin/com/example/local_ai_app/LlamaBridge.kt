package com.example.local_ai_app

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

class LlamaBridge : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

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

    private external fun nativeLoadModel(modelPath: String, contextLength: Int, threads: Int): Boolean
    private external fun nativeUnloadModel()
    private external fun nativeIsModelLoaded(): Boolean
    private external fun nativeGenerate(
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        callback: NativeGenerationCallback
    )
    private external fun nativeCancel()

    private val job = SupervisorJob()
    private val scope = CoroutineScope(job + Dispatchers.IO)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    private val isGenerating = AtomicBoolean(false)
    private var activeRequestId: String? = null

    // Native token & completion callback interface
    interface NativeGenerationCallback {
        fun onToken(token: String)
        fun onComplete(cancelled: Boolean, errorMsg: String)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (!isLibraryAvailable) {
            result.error("NATIVE_LIBRARY_UNAVAILABLE", "Native library libjlexa_native.so failed to load", null)
            return
        }

        when (call.method) {
            "loadModel" -> {
                val modelPath = call.argument<String>("modelPath")
                val contextLength = call.argument<Int>("contextLength") ?: 2048
                val threads = call.argument<Int>("threads") ?: 4

                if (modelPath == null) {
                    result.error("INVALID_ARGS", "modelPath is required", null)
                    return
                }

                scope.launch {
                    try {
                        val loaded = nativeLoadModel(modelPath, contextLength, threads)
                        withContext(Dispatchers.Main) {
                            result.success(loaded)
                        }
                    } catch (e: Throwable) {
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
                        withContext(Dispatchers.Main) {
                            result.success(null)
                        }
                    } catch (e: Throwable) {
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

                if (!isGenerating.compareAndSet(false, true)) {
                    result.error("BUSY", "Another generation is already in progress", null)
                    return
                }

                activeRequestId = requestId
                result.success(null)

                scope.launch {
                    try {
                        nativeGenerate(
                            prompt,
                            maxTokens,
                            temperature,
                            topP,
                            object : NativeGenerationCallback {
                                override fun onToken(token: String) {
                                    mainHandler.post {
                                        eventSink?.success(
                                            mapOf(
                                                "requestId" to requestId,
                                                "type" to "token",
                                                "text" to token
                                            )
                                        )
                                    }
                                }

                                override fun onComplete(cancelled: Boolean, errorMsg: String) {
                                    isGenerating.set(false)
                                    if (activeRequestId == requestId) {
                                        activeRequestId = null
                                    }
                                    mainHandler.post {
                                        if (cancelled) {
                                            eventSink?.success(
                                                mapOf(
                                                    "requestId" to requestId,
                                                    "type" to "cancelled"
                                                )
                                            )
                                        } else if (errorMsg.isNotEmpty()) {
                                            eventSink?.success(
                                                mapOf(
                                                    "requestId" to requestId,
                                                    "type" to "error",
                                                    "message" to errorMsg
                                                )
                                            )
                                        } else {
                                            eventSink?.success(
                                                mapOf(
                                                    "requestId" to requestId,
                                                    "type" to "done"
                                                )
                                            )
                                        }
                                    }
                                }
                            }
                        )
                    } catch (e: Throwable) {
                        isGenerating.set(false)
                        if (activeRequestId == requestId) {
                            activeRequestId = null
                        }
                        mainHandler.post {
                            eventSink?.success(
                                mapOf(
                                    "requestId" to requestId,
                                    "type" to "error",
                                    "message" to (e.message ?: "Generation exception")
                                )
                            )
                        }
                    }
                }
            }

            "cancelGeneration" -> {
                val reqId = call.argument<String>("requestId") ?: activeRequestId
                try {
                    nativeCancel()
                } catch (_: Throwable) {}
                isGenerating.set(false)
                if (reqId != null && activeRequestId == reqId) {
                    activeRequestId = null
                }
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun cleanUp() {
        try {
            nativeCancel()
        } catch (_: Throwable) {}
        isGenerating.set(false)
        activeRequestId = null
        job.cancel()
        eventSink = null
    }
}
