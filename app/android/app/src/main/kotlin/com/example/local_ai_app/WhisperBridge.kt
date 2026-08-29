package com.example.local_ai_app

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID

class WhisperBridge : MethodChannel.MethodCallHandler {

    companion object {
        init {
            try {
                System.loadLibrary("jlexa_native")
            } catch (e: UnsatisfiedLinkError) {
                e.printStackTrace()
            }
        }
    }

    private external fun nativeLoadModel(modelPath: String): Boolean
    private external fun nativeUnloadModel()
    private external fun nativeIsModelLoaded(): Boolean
    private external fun nativeTranscribe(
        samples: FloatArray,
        nThreads: Int,
        language: String
    ): List<Map<String, Any>>?
    private external fun nativeCancel()

    private val scope = CoroutineScope(Dispatchers.IO)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "loadModel" -> {
                val modelPath = call.argument<String>("modelPath")
                if (modelPath == null) {
                    result.error("INVALID_ARGS", "modelPath is required", null)
                    return
                }
                scope.launch {
                    val loaded = nativeLoadModel(modelPath)
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

            "transcribeAudio" -> {
                val audioPath = call.argument<String>("audioPath")
                val lessonId = call.argument<String>("lessonId") ?: UUID.randomUUID().toString()
                val threads = call.argument<Int>("threads") ?: 4

                if (audioPath == null) {
                    result.error("INVALID_ARGS", "audioPath is required", null)
                    return
                }

                scope.launch {
                    try {
                        val pcm = AudioDecoder.decodeTo16kHzMonoPcm(audioPath)
                        if (pcm.isEmpty()) {
                            withContext(Dispatchers.Main) {
                                result.error("DECODE_ERROR", "Could not decode audio file: $audioPath", null)
                            }
                            return@launch
                        }

                        val rawSegments = nativeTranscribe(pcm, threads, "en")
                        val formattedList = mutableListOf<Map<String, Any>>()

                        rawSegments?.forEachIndexed { index, seg ->
                            val segId = "${lessonId}_seg_$index"
                            val startMs = (seg["start_ms"] as? Number)?.toInt() ?: 0
                            val endMs = (seg["end_ms"] as? Number)?.toInt() ?: 0
                            val text = seg["text"] as? String ?: ""
                            val confidence = (seg["confidence"] as? Number)?.toDouble() ?: 1.0
                            val rawTokens = seg["tokens"] as? List<Map<String, Any>> ?: emptyList()

                            formattedList.add(
                                mapOf(
                                    "id" to segId,
                                    "lesson_id" to lessonId,
                                    "start_ms" to startMs,
                                    "end_ms" to endMs,
                                    "text" to text,
                                    "confidence" to confidence,
                                    "is_user_edited" to 0,
                                    "tokens_json" to buildTokensJson(rawTokens)
                                )
                            )
                        }

                        withContext(Dispatchers.Main) {
                            result.success(formattedList)
                        }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) {
                            result.error("TRANSCRIBE_ERROR", e.message, null)
                        }
                    }
                }
            }

            "cancelTranscription" -> {
                nativeCancel()
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private fun buildTokensJson(tokens: List<Map<String, Any>>): String {
        val sb = StringBuilder("[")
        tokens.forEachIndexed { i, tok ->
            val text = (tok["text"] as? String ?: "").replace("\"", "\\\"")
            val startMs = (tok["start_ms"] as? Number)?.toInt() ?: 0
            val endMs = (tok["end_ms"] as? Number)?.toInt() ?: 0
            val conf = (tok["confidence"] as? Number)?.toDouble() ?: 1.0

            sb.append("{\"text\":\"$text\",\"start_ms\":$startMs,\"end_ms\":$endMs,\"confidence\":$conf}")
            if (i < tokens.size - 1) sb.append(",")
        }
        sb.append("]")
        return sb.toString()
    }
}
