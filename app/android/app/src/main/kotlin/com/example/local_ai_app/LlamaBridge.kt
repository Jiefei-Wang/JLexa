package com.example.local_ai_app

import android.content.Intent
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

    private val plugins by lazy { BackendPlugins(requireNotNull(context)) }
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

    private external fun nativeSupportsBenchmark(): Boolean
    private external fun nativeBenchmark(callback: BenchmarkCallback): LongArray
    @Keep
    interface BenchmarkCallback {
        fun onProgress(phase: Int, text: String, promptTokens: Long, generatedTokens: Long, prefillUs: Long, decodeUs: Long)
    }
    private val benchmarkCancelled = AtomicBoolean(false)
    private var benchmarkRequestId: String? = null

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
        when (call.method) {
            "benchmarkSupported" -> scope.launch {
                try {
                    val value = true // The bundled backend supplies benchmark timing; each selected row is checked.
                    withContext(Dispatchers.Main) { result.success(value) }
                } catch (e: Throwable) {
                    withContext(Dispatchers.Main) { result.error("BENCHMARK_ERROR", e.message, null) }
                }
            }
            "runBenchmark" -> runBenchmark(call, result)
            "cancelBenchmark" -> {
                if (call.argument<String>("requestId") == benchmarkRequestId) {
                    benchmarkCancelled.set(true)
                    nativeCancel()
                }
                result.success(null)
            }
            "pluginStatus" -> result.success(plugins.snapshot())
            "importPlugin", "useBuiltinPlugin", "selectPlugin", "deletePlugin" -> {
                if (isGenerating.get() || !isMutating.compareAndSet(false, true)) {
                    result.error("BUSY", "Wait for the current inference operation to finish", null)
                    return
                }
                scope.launch {
                    try {
                        when (call.method) {
                            "importPlugin" -> plugins.importPlugin()
                            "selectPlugin" -> plugins.selectPlugin(requireNotNull(call.argument<String>("id")))
                            "deletePlugin" -> plugins.deletePlugin(requireNotNull(call.argument<String>("id")))
                            else -> plugins.useBuiltin()
                        }
                        withContext(Dispatchers.Main) { isMutating.set(false); result.success(plugins.snapshot()) }
                    } catch (e: Throwable) {
                        withContext(Dispatchers.Main) { isMutating.set(false); result.error("PLUGIN_ERROR", e.message, null) }
                    }
                }
            }
            "getAvailableBackends" -> {
                scope.launch {
                    try {
                        val value = nativeGetAvailableBackends()
                        withContext(Dispatchers.Main) { result.success(value) }
                    } catch (e: Throwable) {
                        withContext(Dispatchers.Main) { result.error("BACKEND_DISCOVERY_ERROR", e.message, null) }
                    }
                }
            }

            "getActiveBackendInfo" -> {
                scope.launch {
                    try {
                        val value = nativeGetActiveBackendInfo()
                        withContext(Dispatchers.Main) { result.success(value) }
                    } catch (e: Throwable) {
                        withContext(Dispatchers.Main) { result.error("BACKEND_INFO_ERROR", e.message, null) }
                    }
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

                if (isGenerating.get() || !isMutating.compareAndSet(false, true)) {
                    result.error("BUSY", "Wait for the current inference operation to finish", null)
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
                        val loaded = try { nativeLoadModel(
                            effectivePath,
                            backend,
                            contextLength,
                            threads,
                            gpuLayers,
                            batchSize,
                            ubatchSize,
                            flashAttention
                        ) } catch (e: Throwable) {
                            if (!plugins.isExternal()) throw e
                            plugins.fallback(e.message ?: "Plugin model load failed")
                            nativeLoadModel(effectivePath, "auto", contextLength, threads, gpuLayers,
                                batchSize, ubatchSize, flashAttention)
                        }
                        plugins.endModelLoad()

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
                            isMutating.set(false)
                            result.success(loaded)
                        }
                    } catch (e: Throwable) {
                        try {
                            newPfd?.close()
                        } catch (_: Throwable) {}
                        plugins.endModelLoad()
                        withContext(Dispatchers.Main) {
                            isMutating.set(false)
                            result.error("LOAD_ERROR", e.message, null)
                        }
                    }
                }
            }

            "unloadModel" -> {
                if (isGenerating.get() || !isMutating.compareAndSet(false, true)) {
                    result.error("BUSY", "Wait for the current inference operation to finish", null)
                    return
                }
                scope.launch {
                    try {
                        nativeUnloadModel()
                        try {
                            activePfd?.close()
                        } catch (_: Throwable) {}
                        activePfd = null
                        withContext(Dispatchers.Main) {
                            isMutating.set(false)
                            result.success(null)
                        }
                    } catch (e: Throwable) {
                        try {
                            activePfd?.close()
                        } catch (_: Throwable) {}
                        activePfd = null
                        withContext(Dispatchers.Main) {
                            isMutating.set(false)
                            result.error("UNLOAD_ERROR", e.message, null)
                        }
                    }
                }
            }

            "isModelLoaded" -> {
                scope.launch {
                    try {
                        val value = nativeIsModelLoaded()
                        withContext(Dispatchers.Main) { result.success(value) }
                    } catch (e: Throwable) {
                        withContext(Dispatchers.Main) { result.error("STATUS_ERROR", e.message, null) }
                    }
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

                if (isMutating.get() || !isGenerating.compareAndSet(false, true)) {
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

    private fun runBenchmark(call: MethodCall, result: MethodChannel.Result) {
        val modelPath = call.argument<String>("modelPath")
        val id = call.argument<String>("requestId")
        val backends = call.argument<List<String>>("backends")?.distinct().orEmpty()
        if (modelPath.isNullOrEmpty() || id == null || backends.isEmpty() ||
            backends.any { it !in listOf("cpu", "vulkan", "opencl") && !it.startsWith("plugin:") }) {
            result.error("INVALID_ARGS", "Select a loaded model and at least one backend", null)
            return
        }
        if (isGenerating.get() || !isMutating.compareAndSet(false, true)) {
            result.error("BUSY", "Wait for the current AI operation to finish", null)
            return
        }
        benchmarkRequestId = id
        benchmarkCancelled.set(false)
        nativeResetCancellation()
        scope.launch {
            val rows = mutableListOf<Map<String, Any>>()
            var newPfd: ParcelFileDescriptor? = null
            var changedModel = false
            var restored = true
            var failure = ""
            var original: Map<String, Any>? = null
            val originalPlugin = plugins.selectedId()
            fun event(stage: String, backend: String = "", extra: Map<String, Any> = emptyMap()) {
                sendEvent(mapOf("type" to "benchmark", "requestId" to id, "stage" to stage, "backend" to backend) + extra)
            }
            fun load(backend: String, config: Map<String, Any>? = null): Boolean {
                fun number(key: String, fallback: Int) = (config?.get(key) as? Number)?.toInt()
                    ?: call.argument<Int>(key) ?: fallback
                // Each plugin load gets a fresh SAF open-file description. A plugin
                // may advance the borrowed descriptor's offset while reading GGUF.
                val descriptor = if (modelPath.startsWith("content://")) {
                    requireNotNull(context).contentResolver.openFileDescriptor(Uri.parse(modelPath), "r")
                        ?: error("Could not open the selected model")
                } else null
                val effectivePath = descriptor?.let { "/proc/self/fd/${it.fd}" } ?: modelPath
                plugins.beginModelLoad()
                try {
                    return nativeLoadModel(effectivePath, backend, number("contextLength", 2048), number("threads", 4),
                        number("gpuLayers", -1), number("batchSize", 512), number("ubatchSize", 512), number("flashAttention", -1))
                } finally {
                    plugins.endModelLoad()
                    newPfd?.close()
                    newPfd = descriptor
                }
            }
            try {
                check(nativeIsModelLoaded()) { "Load a language model before benchmarking" }
                original = nativeGetActiveBackendInfo()
                for (backend in backends) {
                    if (benchmarkCancelled.get()) break
                    event("loading", backend)
                    val row = mutableMapOf<String, Any>("backend" to backend, "status" to "failed")
                    try {
                        changedModel = true
                        val pluginId = if (backend.startsWith("plugin:")) backend.removePrefix("plugin:") else ""
                        if (plugins.selectedId() != pluginId) plugins.selectPlugin(pluginId, persist = false)
                        check(nativeSupportsBenchmark()) { "This backend does not support benchmark timing. Import an updated plugin." }
                        val device = if (pluginId.isEmpty()) backend else "auto"
                        val available = nativeGetAvailableBackends().associateBy { it["backend"] as String }
                        check(device == "auto" || available[device]?.get("available") == true) {
                            available[device]?.get("reasonUnavailable")?.toString() ?: "Backend unavailable"
                        }
                        check(load(device)) { "Model could not load on $backend" }
                        if (benchmarkCancelled.get()) break
                        val active = nativeGetActiveBackendInfo().orEmpty()
                        check(device == "auto" || active["backend"] == device) { "Requested $backend but engine activated ${active["backend"]}" }
                        row["device"] = active["deviceName"] ?: backend
                        row["runtime"] = active
                        event("prefill", backend)
                        val stats = nativeBenchmark(object : BenchmarkCallback {
                            override fun onProgress(phase: Int, text: String, promptTokens: Long, generatedTokens: Long, prefillUs: Long, decodeUs: Long) {
                                event(when(phase) { 0 -> "input"; 1 -> "decode"; else -> "token" }, backend,
                                    mapOf("text" to text, "promptTokens" to promptTokens, "generatedTokens" to generatedTokens,
                                        "prefillUs" to prefillUs, "decodeUs" to decodeUs))
                            }
                        })
                        row.putAll(mapOf("sourceTokens" to stats[0], "promptTokens" to stats[1], "generatedTokens" to stats[2],
                            "decodedTokens" to stats[3], "prefillUs" to stats[4], "decodeUs" to stats[5],
                            "status" to if (stats[6] == 1L || benchmarkCancelled.get()) "cancelled" else "completed"))
                    } catch (e: Throwable) {
                        row["status"] = if (benchmarkCancelled.get()) "cancelled" else "failed"
                        row["error"] = e.message ?: "Benchmark failed"
                    }
                    rows.add(row)
                    event("row", backend, mapOf("result" to row))
                }
            } catch (e: Throwable) { failure = e.message ?: "Benchmark failed" }
            finally {
                if (changedModel && original != null) {
                    event("restoring")
                    // Stop remains latched for the test; restoration needs a fresh cancellation flag.
                    try {
                        plugins.selectPlugin(originalPlugin, persist = false)
                        nativeResetCancellation()
                        check(load(original["backend"] as? String ?: "auto", original)) { "Could not restore the previous backend" }
                        activePfd?.close()
                        activePfd = newPfd
                        newPfd = null
                    } catch (e: Throwable) {
                        restored = false
                        failure = "Could not restore the previous model/backend: ${e.message}"
                        try { nativeUnloadModel() } catch (_: Throwable) {}
                        activePfd?.close(); activePfd = null
                    }
                }
                newPfd?.close()
                withContext(Dispatchers.Main) {
                    benchmarkRequestId = null
                    isMutating.set(false)
                    result.success(mapOf("rows" to rows, "cancelled" to benchmarkCancelled.get(),
                        "restored" to restored, "error" to failure))
                }
            }
        }
    }

    fun cleanUp() {
        benchmarkCancelled.set(true)
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

