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
import org.json.JSONArray
import org.json.JSONObject
import androidx.annotation.Keep
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

@Keep
class WhisperBridge(private val context: Context? = null) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

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

    private external fun nativeLoadModel(modelPath: String): Boolean
    private external fun nativeUnloadModel()
    private external fun nativeIsModelLoaded(): Boolean
    private external fun nativeTranscribe(
        samples: FloatArray,
        sampleCount: Int,
        nThreads: Int,
        language: String,
        progressCallback: NativeProgressCallback?
    ): List<Map<String, Any>>?
    private external fun nativeCancel()
    private external fun nativeResetCancellation()

    private val job = SupervisorJob()
    private val scope = CoroutineScope(job + Dispatchers.IO)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    private val isTranscribing = AtomicBoolean(false)
    private val isCancelled = AtomicBoolean(false)
    private var activeRequestId: String? = null

    @Keep
    interface NativeProgressCallback {
        @Keep
        fun onProgress(progress: Int)
    }

    @Keep
    class ProgressCallback(
        private val bridge: WhisperBridge,
        private val requestId: String
    ) : NativeProgressCallback {
        override fun onProgress(progress: Int) {
            bridge.mainHandler.post {
                bridge.eventSink?.success(
                    mapOf(
                        "requestId" to requestId,
                        "type" to "progress",
                        "progress" to (progress.toDouble() / 100.0).coerceIn(0.0, 1.0)
                    )
                )
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (!isLibraryAvailable && call.method != "extractAudioInfo" && call.method != "getAudioMetadata") {
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

                        val loaded = nativeLoadModel(effectivePath)
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

            "getAudioMetadata" -> {
                val audioPath = call.argument<String>("audioPath")
                if (audioPath == null) {
                    result.error("INVALID_ARGS", "audioPath is required", null)
                    return
                }
                scope.launch {
                    try {
                        val durationMs = AudioDecoder.getAudioMetadata(audioPath) ?: 0L
                        withContext(Dispatchers.Main) {
                            result.success(mapOf("durationMs" to durationMs))
                        }
                    } catch (e: Throwable) {
                        withContext(Dispatchers.Main) {
                            result.error("METADATA_ERROR", e.message, null)
                        }
                    }
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
                        val waveformResult = AudioDecoder.extractWaveformOnly(audioPath, numPeaks)
                        if (waveformResult == null) {
                            withContext(Dispatchers.Main) {
                                result.error("DECODE_ERROR", "Failed to decode audio file: $audioPath", null)
                            }
                            return@launch
                        }
                        withContext(Dispatchers.Main) {
                            result.success(
                                mapOf(
                                    "durationMs" to waveformResult.durationMs,
                                    "peaks" to waveformResult.waveformPeaks
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
                val requestId = call.argument<String>("requestId") ?: UUID.randomUUID().toString()
                val threads = call.argument<Int>("threads") ?: 4
                val cutStartMs = call.argument<Int>("cutStartMs")
                val cutEndMs = call.argument<Int>("cutEndMs")
                val cutId = call.argument<String>("cutId")
                val cutRevision = call.argument<Int>("cutRevision")
                val modelId = call.argument<String>("modelId")

                if (audioPath == null) {
                    result.error("INVALID_ARGS", "audioPath is required", null)
                    return
                }

                if (!isTranscribing.compareAndSet(false, true)) {
                    result.error("BUSY", "Another transcription is currently in progress", null)
                    return
                }

                activeRequestId = requestId
                isCancelled.set(false)

                scope.launch {
                    try {
                        nativeResetCancellation()
                        val pcm = AudioDecoder.decodeTo16kHzMonoPcm(audioPath, isCancelled = { isCancelled.get() })
                        if (isCancelled.get()) {
                            withContext(Dispatchers.Main) {
                                result.error("CANCELLED", "Transcription was cancelled during decoding", null)
                            }
                            return@launch
                        }

                        if (pcm.validSampleCount == 0 || pcm.samples.isEmpty()) {
                            withContext(Dispatchers.Main) {
                                result.error("DECODE_ERROR", "Could not decode audio file: $audioPath", null)
                            }
                            return@launch
                        }

                        val rangeStartSample = ((cutStartMs ?: 0).toLong() * 16L)
                            .coerceIn(0L, pcm.validSampleCount.toLong()).toInt()
                        val rangeEndSample = ((cutEndMs ?: (pcm.validSampleCount / 16)).toLong() * 16L)
                            .coerceIn(rangeStartSample.toLong(), pcm.validSampleCount.toLong()).toInt()
                        if (rangeEndSample <= rangeStartSample) {
                            withContext(Dispatchers.Main) {
                                result.error("INVALID_RANGE", "Cut has no decodable audio", null)
                            }
                            return@launch
                        }
                        val targetSamples = if (cutId != null) {
                            pcm.samples.copyOfRange(rangeStartSample, rangeEndSample)
                        } else pcm.samples
                        val absoluteOffsetMs = if (cutId != null) cutStartMs ?: 0 else 0
                        val rawSegments = nativeTranscribe(
                            targetSamples,
                            targetSamples.size,
                            threads,
                            "en",
                            ProgressCallback(this@WhisperBridge, requestId)
                        )

                        if (isCancelled.get()) {
                            withContext(Dispatchers.Main) {
                                result.error("CANCELLED", "Transcription was cancelled", null)
                            }
                            return@launch
                        }

                        val formattedList = mutableListOf<Map<String, Any>>()
                        rawSegments?.forEachIndexed { index, seg ->
                            val segId = cutId ?: "${lessonId}_seg_$index"
                            val startMs = ((seg["start_ms"] as? Number)?.toInt() ?: 0) + absoluteOffsetMs
                            val endMs = ((seg["end_ms"] as? Number)?.toInt() ?: 0) + absoluteOffsetMs
                            val text = seg["text"] as? String ?: ""
                            val confidence = (seg["confidence"] as? Number)?.toDouble() ?: -1.0
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
                                    "tokens_json" to buildTokensJson(rawTokens, absoluteOffsetMs),
                                    "revision" to (cutRevision ?: 0),
                                    "transcript_cut_revision" to (cutRevision ?: 0),
                                    "transcript_model_id" to (modelId ?: "")
                                )
                            )
                        }

                        withContext(Dispatchers.Main) {
                            result.success(formattedList)
                        }
                    } catch (e: Throwable) {
                        withContext(Dispatchers.Main) {
                            result.error("TRANSCRIBE_ERROR", e.message ?: "Transcription exception", null)
                        }
                    } finally {
                        isTranscribing.set(false)
                        if (activeRequestId == requestId) {
                            activeRequestId = null
                        }
                    }
                }
            }

            "cancelTranscription" -> {
                val reqId = call.argument<String>("requestId")
                if (reqId == null || reqId == activeRequestId) {
                    isCancelled.set(true)
                    try {
                        nativeCancel()
                    } catch (_: Throwable) {}
                }
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private fun buildTokensJson(tokens: List<Map<String, Any>>, offsetMs: Int = 0): String {
        val jsonArray = JSONArray()
        for (tok in tokens) {
            val obj = JSONObject()
            obj.put("text", tok["text"] as? String ?: "")
            obj.put("start_ms", ((tok["start_ms"] as? Number)?.toInt() ?: 0) + offsetMs)
            obj.put("end_ms", ((tok["end_ms"] as? Number)?.toInt() ?: 0) + offsetMs)
            obj.put("confidence", (tok["confidence"] as? Number)?.toDouble() ?: -1.0)
            jsonArray.put(obj)
        }
        return jsonArray.toString()
    }

    fun cleanUp() {
        isCancelled.set(true)
        try {
            nativeCancel()
            nativeUnloadModel()
        } catch (_: Throwable) {}
        try {
            activePfd?.close()
            activePfd = null
        } catch (_: Throwable) {}
        isTranscribing.set(false)
        activeRequestId = null
        job.cancel()
        eventSink = null
    }
}
