package com.example.local_ai_app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import androidx.annotation.Keep
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

@Keep
class WhisperBridge(private val context: Context? = null) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val plugins by lazy { BackendPlugins(requireNotNull(context), speech = true) }
    private val isMutating = AtomicBoolean(false)
    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?) =
        plugins.handleActivityResult(requestCode, resultCode, data)
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
    private val audioEnergyCache = AudioEnergy.Cache()
    @Volatile private var activeRequestId: String? = null

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
                if (bridge.activeRequestId != requestId || bridge.isCancelled.get()) return@post
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

    private fun releaseRequest(requestId: String) {
        if (activeRequestId == requestId) {
            activeRequestId = null
            isTranscribing.set(false)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (!isLibraryAvailable && call.method !in setOf("extractAudioInfo", "getAudioMetadata", "exportAudioClip", "getAudioEnergy")) {
            result.error("NATIVE_LIBRARY_UNAVAILABLE", "Native library libjlexa_native.so failed to load", null)
            return
        }

        if (call.method in setOf("extractAudioInfo", "getAudioMetadata", "exportAudioClip", "getAudioEnergy", "cancelTranscription", "stopBenchmark")) {
            dispatch(call, result)
            return
        }
        scope.launch {
            try {
                plugins.initialize()
                withContext(Dispatchers.Main) { dispatch(call, result) }
            } catch (e: Throwable) {
                withContext(Dispatchers.Main) { result.error("PLUGIN_ERROR", e.message, null) }
            }
        }
    }

    private fun dispatch(call: MethodCall, result: MethodChannel.Result) {
        if (call.method in setOf("loadModel", "unloadModel", "importPlugin", "selectPlugin", "deletePlugin", "useBuiltinPlugin")) {
            if (isTranscribing.get() || !isMutating.compareAndSet(false, true)) {
                result.error("BUSY", "Wait for the current speech operation to finish", null)
                return
            }
        }
        when (call.method) {
            "getAudioEnergy" -> {
                val audioPath = call.argument<String>("audioPath")
                val startMs = call.argument<Number>("startMs")?.toLong()
                val endMs = call.argument<Number>("endMs")?.toLong()
                if (audioPath.isNullOrBlank() || startMs == null || endMs == null ||
                    startMs < 0 || endMs <= startMs || endMs > Int.MAX_VALUE ||
                    endMs - startMs > Int.MAX_VALUE / 16) {
                    result.error("INVALID_RANGE", "audioPath and a valid 0 <= startMs < endMs audio range are required", null)
                    return
                }
                scope.launch {
                    try {
                        val energy = audioEnergyCache.find(audioPath, startMs, endMs) ?: run {
                            // Independent from speech cancellation; the Dart caller owns stale-result rejection.
                            val pcm = AudioRangeDecoder.decode(audioPath, startMs, endMs) { !isActive }
                            AudioEnergy.fromPcm(pcm.samples, pcm.validSampleCount, startMs).also {
                                audioEnergyCache.put(audioPath, it)
                            }
                        }
                        withContext(Dispatchers.Main) { result.success(energy.toMap()) }
                    } catch (e: Throwable) {
                        withContext(Dispatchers.Main) { result.error("ENERGY_ERROR", e.message ?: "Could not extract audio energy", null) }
                    }
                }
            }
            "runBenchmark" -> runBenchmark(call, result)
            "stopBenchmark" -> {
                if (call.argument<String>("requestId") == activeRequestId) {
                    isCancelled.set(true)
                    try { nativeCancel() } catch (_: Throwable) {}
                }
                result.success(null)
            }
            "pluginStatus" -> result.success(plugins.snapshot())
            "importPlugin", "selectPlugin", "deletePlugin", "useBuiltinPlugin" -> scope.launch {
                try {
                    when (call.method) {
                        "importPlugin" -> plugins.importPlugin()
                        "selectPlugin" -> plugins.selectPlugin(requireNotNull(call.argument<String>("id")))
                        "deletePlugin" -> plugins.deletePlugin(requireNotNull(call.argument<String>("id")))
                        else -> plugins.useBuiltin()
                    }
                    withContext(Dispatchers.Main) { result.success(plugins.snapshot()) }
                } catch (e: Throwable) {
                    withContext(Dispatchers.Main) { result.error("PLUGIN_ERROR", e.message, null) }
                } finally { isMutating.set(false) }
            }
            "loadModel" -> {
                val modelPath = call.argument<String>("modelPath")
                if (modelPath == null) {
                    isMutating.set(false)
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

                        plugins.beginModelLoad()
                        val loaded = try {
                            val ok = nativeLoadModel(effectivePath)
                            if (!ok && plugins.isExternal()) throw IllegalStateException("Whisper plugin could not load this model")
                            ok
                        } catch (e: Throwable) {
                            if (!plugins.isExternal()) throw e
                            plugins.fallback(e.message ?: "Whisper plugin model load failed")
                            nativeLoadModel(effectivePath)
                        } finally { plugins.endModelLoad() }
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
                    } finally { isMutating.set(false) }
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
                    } finally { isMutating.set(false) }
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

            "exportAudioClip" -> {
                val audioPath = call.argument<String>("audioPath")
                val outputPath = call.argument<String>("outputPath")
                val startMs = call.argument<Number>("startMs")?.toLong()
                val endMs = call.argument<Number>("endMs")?.toLong()
                if (audioPath == null || outputPath == null || startMs == null || endMs == null || startMs < 0 || endMs <= startMs) {
                    result.error("INVALID_ARGS", "audioPath, outputPath and 0 <= startMs < endMs are required", null)
                    return
                }
                scope.launch {
                    try {
                        val exported = AudioClipExporter.export(audioPath, startMs, endMs, outputPath) { !isActive }
                        withContext(Dispatchers.Main) { result.success(exported) }
                    } catch (e: Throwable) {
                        withContext(Dispatchers.Main) { result.error("EXPORT_ERROR", e.message, null) }
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
                if (cutId != null && (cutStartMs == null || cutEndMs == null || cutStartMs < 0 || cutEndMs <= cutStartMs)) {
                    result.error("INVALID_RANGE", "A cut requires 0 <= cutStartMs < cutEndMs", null)
                    return
                }

                if (isMutating.get() || !isTranscribing.compareAndSet(false, true)) {
                    result.error("BUSY", "Another transcription is currently in progress", null)
                    return
                }

                activeRequestId = requestId
                isCancelled.set(false)
                // Reset before launching so a cancel arriving immediately after the request
                // cannot be erased later by the worker.
                try {
                    nativeResetCancellation()
                } catch (e: Throwable) {
                    releaseRequest(requestId)
                    result.error("TRANSCRIBE_ERROR", e.message, null)
                    return
                }

                scope.launch {
                    try {
                        val decodeStarted = SystemClock.elapsedRealtime()
                        val pcm = AudioDecoder.decodeTo16kHzMonoPcm(audioPath,
                            isCancelled = { isCancelled.get() || !isActive },
                            startMs = if (cutId != null) cutStartMs?.toLong() else null,
                            endMs = if (cutId != null) cutEndMs?.toLong() else null)
                        Log.i("JLexaWhisper", "decode request=$requestId elapsed_ms=${SystemClock.elapsedRealtime() - decodeStarted} samples=${pcm.validSampleCount}")
                        if (isCancelled.get()) {
                            withContext(Dispatchers.Main) {
                                releaseRequest(requestId)
                                result.error("CANCELLED", "Transcription was cancelled during decoding", null)
                            }
                            return@launch
                        }

                        if (pcm.validSampleCount == 0 || pcm.samples.isEmpty()) {
                            withContext(Dispatchers.Main) {
                                releaseRequest(requestId)
                                result.error("DECODE_ERROR", "Could not decode audio file: $audioPath", null)
                            }
                            return@launch
                        }

                        val absoluteOffsetMs = if (cutId != null) cutStartMs ?: 0 else 0
                        if (cutId?.startsWith("window-") == true) {
                            audioEnergyCache.put(audioPath, AudioEnergy.fromPcm(
                                pcm.samples, pcm.validSampleCount, absoluteOffsetMs.toLong()
                            ))
                        }
                        val inferenceStarted = SystemClock.elapsedRealtime()
                        val rawSegments = nativeTranscribe(
                            pcm.samples,
                            pcm.validSampleCount,
                            threads,
                            "en",
                            ProgressCallback(this@WhisperBridge, requestId)
                        )
                        Log.i("JLexaWhisper", "inference request=$requestId backend=${plugins.snapshot()["name"]} elapsed_ms=${SystemClock.elapsedRealtime() - inferenceStarted}")

                        if (isCancelled.get()) {
                            withContext(Dispatchers.Main) {
                                releaseRequest(requestId)
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
                            releaseRequest(requestId)
                            result.success(formattedList)
                        }
                    } catch (e: Throwable) {
                        withContext(Dispatchers.Main) {
                            releaseRequest(requestId)
                            result.error(if (isCancelled.get()) "CANCELLED" else "TRANSCRIBE_ERROR", e.message ?: "Transcription exception", null)
                        }
                    } finally {
                        releaseRequest(requestId)
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

    private fun benchmarkEvent(id: String, values: Map<String, Any>) {
        mainHandler.post {
            if (activeRequestId == id) eventSink?.success(
                mapOf("type" to "benchmark", "requestId" to id) + values)
        }
    }

    @Keep
    class BenchmarkProgressCallback(
        private val bridge: WhisperBridge,
        private val id: String,
        private val backend: String,
        private val sample: String
    ) : NativeProgressCallback {
        override fun onProgress(progress: Int) {
            bridge.benchmarkEvent(id, mapOf("stage" to "progress", "backend" to backend,
                "sample" to sample, "progress" to progress))
        }
    }

    // These fixed mono 16 kHz PCM fixtures are decoded before starting the timer.
    private fun benchmarkSamples(name: String): FloatArray {
        val bytes = requireNotNull(context).assets.open("benchmark/$name.wav").use { it.readBytes() }
        val buffer = java.nio.ByteBuffer.wrap(bytes).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        var offset = 12
        while (offset + 8 <= bytes.size) {
            val size = buffer.getInt(offset + 4)
            require(size >= 0 && size <= bytes.size - offset - 8) { "Invalid benchmark audio" }
            if (String(bytes, offset, 4, Charsets.US_ASCII) == "data") {
                return FloatArray(size / 2) { buffer.getShort(offset + 8 + it * 2) / 32768f }
            }
            offset += 8 + size + (size and 1)
        }
        error("Benchmark audio is missing PCM data")
    }

    private fun runBenchmark(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("requestId")
        val modelPath = call.argument<String>("modelPath")
        val backends = call.argument<List<String>>("backends")
        if (id == null || modelPath == null || backends.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "Select a speech model and backend", null)
            return
        }
        if (isMutating.get() || !isTranscribing.compareAndSet(false, true)) {
            result.error("BUSY", "Wait for the current speech operation to finish", null)
            return
        }
        activeRequestId = id
        isCancelled.set(false)
        val original = plugins.selectedId()
        val effectivePath = activePfd?.let { "/proc/self/fd/${it.fd}" } ?: modelPath
        scope.launch {
            val rows = mutableListOf<Map<String, Any>>()
            var errorMessage = ""
            try {
                check(nativeIsModelLoaded()) { "Load a Whisper model before benchmarking" }
                val audio = listOf("short", "long").associateWith { benchmarkSamples(it) }
                for (backend in backends.distinct()) {
                    if (isCancelled.get()) break
                    val row = mutableMapOf<String, Any>("backend" to backend, "status" to "completed")
                    try {
                        benchmarkEvent(id, mapOf("stage" to "loading", "backend" to backend))
                        nativeUnloadModel()
                        plugins.selectPlugin(if (backend == "cpu") "" else backend.removePrefix("plugin:"), persist = false)
                        plugins.beginModelLoad()
                        try { check(nativeLoadModel(effectivePath)) { "Could not load model with this backend" } }
                        finally { plugins.endModelLoad() }
                        for ((sample, pcm) in audio) {
                            if (isCancelled.get()) break
                            nativeResetCancellation()
                            if (isCancelled.get()) { nativeCancel(); break }
                            benchmarkEvent(id, mapOf("stage" to "progress", "backend" to backend,
                                "sample" to sample, "progress" to 0))
                            val started = SystemClock.elapsedRealtimeNanos()
                            val segments = nativeTranscribe(pcm, pcm.size, 4, "en",
                                BenchmarkProgressCallback(this@WhisperBridge, id, backend, sample))
                            val elapsedUs = (SystemClock.elapsedRealtimeNanos() - started) / 1000
                            if (isCancelled.get()) break
                            checkNotNull(segments) { "Speech inference failed" }
                            val text = segments.joinToString(" ") { it["text"] as? String ?: "" }.trim()
                            row["${sample}Us"] = elapsedUs
                            row["${sample}Text"] = text
                            row["${sample}AudioMs"] = pcm.size * 1000 / 16000
                            benchmarkEvent(id, mapOf("stage" to "sample", "backend" to backend,
                                "sample" to sample, "text" to text, "elapsedUs" to elapsedUs))
                        }
                        if (isCancelled.get()) row["status"] = "cancelled"
                    } catch (e: Throwable) {
                        row["status"] = if (isCancelled.get()) "cancelled" else "failed"
                        row["error"] = e.message ?: "Speech benchmark failed"
                    }
                    rows.add(row)
                    benchmarkEvent(id, mapOf("stage" to "row", "backend" to backend, "result" to row))
                }
            } catch (e: Throwable) {
                errorMessage = e.message ?: "Speech benchmark failed"
            } finally {
                benchmarkEvent(id, mapOf("stage" to "restoring"))
                try {
                    nativeUnloadModel()
                    plugins.selectPlugin(original, persist = false)
                    nativeResetCancellation()
                    plugins.beginModelLoad()
                    try { check(nativeLoadModel(effectivePath)) { "Could not restore speech model" } }
                    finally { plugins.endModelLoad() }
                } catch (e: Throwable) {
                    errorMessage = "Could not restore selected backend: ${e.message}"
                    try {
                        plugins.fallback(errorMessage)
                        nativeResetCancellation()
                        check(nativeLoadModel(effectivePath)) { "Built-in speech model restoration failed" }
                    } catch (fallback: Throwable) {
                        errorMessage += "; ${fallback.message}"
                    }
                }
                withContext(Dispatchers.Main) {
                    val loaded = try { nativeIsModelLoaded() } catch (_: Throwable) { false }
                    releaseRequest(id)
                    result.success(mapOf("rows" to rows, "cancelled" to isCancelled.get(),
                        "error" to errorMessage, "modelLoaded" to loaded))
                }
            }
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
        audioEnergyCache.close()
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
