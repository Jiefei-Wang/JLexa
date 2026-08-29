package com.example.local_ai_app

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

class WhisperBridge : MethodChannel.MethodCallHandler {

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

    private external fun nativeLoadModel(modelPath: String): Boolean
    private external fun nativeUnloadModel()
    private external fun nativeIsModelLoaded(): Boolean
    private external fun nativeTranscribe(
        samples: FloatArray,
        nThreads: Int,
        language: String,
        progressCallback: NativeProgressCallback?
    ): List<Map<String, Any>>?
    private external fun nativeCancel()

    private val job = SupervisorJob()
    private val scope = CoroutineScope(job + Dispatchers.IO)

    interface NativeProgressCallback {
        fun onProgress(progress: Int)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (!isLibraryAvailable && call.method != "extractAudioInfo") {
            result.error("NATIVE_LIBRARY_UNAVAILABLE", "Native library libjlexa_native.so failed to load", null)
            return
        }

        when (call.method) {
            "loadModel" -> {
                val modelPath = call.argument<String>("modelPath")
                if (modelPath == null) {
                    result.error("INVALID_ARGS", "modelPath is required", null)
                    return
                }
                scope.launch {
                    try {
                        val loaded = nativeLoadModel(modelPath)
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

            "extractAudioInfo" -> {
                val audioPath = call.argument<String>("audioPath")
                val numPeaks = call.argument<Int>("numPeaks") ?: 200
                if (audioPath == null) {
                    result.error("INVALID_ARGS", "audioPath is required", null)
                    return
                }

                scope.launch {
                    try {
                        val decoded = AudioDecoder.decodeAudioFull(audioPath, numPeaks)
                        if (decoded == null) {
                            withContext(Dispatchers.Main) {
                                result.error("DECODE_ERROR", "Failed to decode audio file: $audioPath", null)
                            }
                            return@launch
                        }
                        withContext(Dispatchers.Main) {
                            result.success(
                                mapOf(
                                    "durationMs" to decoded.durationMs,
                                    "peaks" to decoded.waveformPeaks
                                )
                            )
                        }
                    } catch (e: Throwable) {
                        withContext(Dispatchers.Main) {
                            result.error("DECODE_ERROR", e.message, null)
                        }
                    }
                }
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

                        val rawSegments = nativeTranscribe(pcm, threads, "en", null)
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
                    } catch (e: Throwable) {
                        withContext(Dispatchers.Main) {
                            result.error("TRANSCRIBE_ERROR", e.message, null)
                        }
                    }
                }
            }

            "cancelTranscription" -> {
                try {
                    nativeCancel()
                } catch (_: Throwable) {}
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private fun buildTokensJson(tokens: List<Map<String, Any>>): String {
        val jsonArray = JSONArray()
        for (tok in tokens) {
            val obj = JSONObject()
            obj.put("text", tok["text"] as? String ?: "")
            obj.put("start_ms", (tok["start_ms"] as? Number)?.toInt() ?: 0)
            obj.put("end_ms", (tok["end_ms"] as? Number)?.toInt() ?: 0)
            obj.put("confidence", (tok["confidence"] as? Number)?.toDouble() ?: 1.0)
            jsonArray.put(obj)
        }
        return jsonArray.toString()
    }

    fun cleanUp() {
        try {
            nativeCancel()
        } catch (_: Throwable) {}
        job.cancel()
    }
}
