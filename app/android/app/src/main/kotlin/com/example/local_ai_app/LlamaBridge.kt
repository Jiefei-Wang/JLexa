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
    interface NativeGenerationCallback {
        fun onToken(token: String)
        fun onComplete(cancelled: Boolean, errorMsg: String)
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
                            object : NativeGenerationCallback {
                                override fun onToken(token: String) {
                                    sendEvent(
                                        mapOf(
                                            "requestId" to requestId,
                                            "type" to "token",
                                            "text" to token
                                        )
                                    )
                                }

                                override fun onComplete(cancelled: Boolean, errorMsg: String) {
                                    isGenerating.set(false)
                                    if (activeRequestId == requestId) {
                                        activeRequestId = null
                                    }
                                    if (cancelled) {
                                        sendEvent(
                                            mapOf(
                                                "requestId" to requestId,
                                                "type" to "cancelled"
                                            )
                                        )
                                    } else if (errorMsg.isNotEmpty()) {
                                        sendEvent(
                                            mapOf(
                                                "requestId" to requestId,
                                                "type" to "error",
                                                "message" to errorMsg
                                            )
                                        )
                                    } else {
                                        sendEvent(
                                            mapOf(
                                                "requestId" to requestId,
                                                "type" to "done"
                                            )
                                        )
                                    }
                                }
                            }
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
        isGenerating.set(false)
        activeRequestId = null
        job.cancel()
        eventSink = null
    }
}

