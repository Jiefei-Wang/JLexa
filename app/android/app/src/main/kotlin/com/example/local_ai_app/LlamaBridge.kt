package com.example.local_ai_app

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class LlamaBridge : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        init {
            try {
                System.loadLibrary("jlexa_native")
            } catch (e: UnsatisfiedLinkError) {
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
        callback: TokenCallback
    )
    private external fun nativeCancel()

    private val scope = CoroutineScope(Dispatchers.IO)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    // Native token callback interface
    interface TokenCallback {
        fun onToken(token: String)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
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
                    val loaded = nativeLoadModel(modelPath, contextLength, threads)
                    withContext(Dispatchers.Main) {
                        result.success(loaded)
                    }
                }
            }

            "unloadModel" -> {
                scope.launch {
                    nativeUnloadModel()
                    withContext(Dispatchers.Main) {
                        result.success(null)
                    }
                }
            }

            "isModelLoaded" -> {
                result.success(nativeIsModelLoaded())
            }

            "startGeneration" -> {
                val prompt = call.argument<String>("prompt") ?: ""
                val maxTokens = call.argument<Int>("maxTokens") ?: 512
                val temperature = (call.argument<Double>("temperature") ?: 0.7).toFloat()
                val topP = (call.argument<Double>("topP") ?: 0.9).toFloat()

                result.success(null)

                scope.launch {
                    try {
                        nativeGenerate(
                            prompt,
                            maxTokens,
                            temperature,
                            topP,
                            object : TokenCallback {
                                override fun onToken(token: String) {
                                    mainHandler.post {
                                        eventSink?.success(token)
                                    }
                                }
                            }
                        )
                    } catch (e: Exception) {
                        mainHandler.post {
                            eventSink?.error("GENERATION_ERROR", e.message, null)
                        }
                    }
                }
            }

            "cancelGeneration" -> {
                nativeCancel()
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
}
