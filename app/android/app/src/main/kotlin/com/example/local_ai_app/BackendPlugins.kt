package com.example.local_ai_app

import android.app.Activity
import android.content.*
import android.net.Uri
import android.os.*
import android.provider.OpenableColumns
import androidx.annotation.Keep
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

/** Small private-file catalog; importing never switches the active backend. */
@Keep
class BackendPlugins(private val context: Context) {
    companion object { const val PICK_PLUGIN = 7412 }
    external fun nativeSelect(path: String): Array<String>
    external fun nativeDevices(): List<Map<String, Any>>
    private val prefs = context.getSharedPreferences("backend_plugins", Context.MODE_PRIVATE)
    private val directory = File(context.noBackupFilesDir, "backend_plugins").apply { mkdirs() }
    private val lock = Mutex()
    private var initialized = false
    private var picker: CompletableDeferred<Uri?>? = null
    private var info = arrayOf("Built-in", "llama.cpp", "1.0.0", "CPU / Vulkan / OpenCL")
    private var selected = ""
    private var status = prefs.getString("status", "Loaded") ?: "Loaded"
    private var error = prefs.getString("error", "") ?: ""

    private val installed = mutableListOf<Map<String, String>>()
    private var builtinDevices: List<Map<String, Any>> = emptyList()
    fun selectedId(): String = if (selected.isEmpty()) "" else File(selected).nameWithoutExtension
    fun snapshot(): Map<String, Any> = mapOf("name" to info[0], "engine" to info[1],
        "version" to info[2], "backendType" to info[3], "status" to status,
        "error" to error, "external" to selected.isNotEmpty(), "id" to selectedId(),
        "fileName" to (installed.find { it["id"] == selectedId() }?.get("fileName") ?: ""),
        "installed" to installed.toList(), "builtinBackends" to builtinDevices)

    private fun saveCatalog() {
        check(prefs.edit().putString("installed", JSONArray(installed.map { JSONObject(it) }).toString()).commit()) {
            "Could not save imported backends"
        }
    }
    private fun record(path: String, metadata: Array<String>, name: String): Map<String, String> = mapOf(
        "id" to File(path).nameWithoutExtension, "name" to metadata[0], "engine" to metadata[1],
        "version" to metadata[2], "backendType" to metadata[3], "fileName" to name)

    private fun save() {
        check(prefs.edit().putString("selected", selected).putString("status", status)
            .putString("error", error).commit()) { "Could not save backend selection" }
    }

    suspend fun initialize() = lock.withLock {
        if (initialized) return@withLock
        val saved = runCatching { JSONArray(prefs.getString("installed", "[]")) }.getOrDefault(JSONArray())
        for (i in 0 until saved.length()) {
            val entry = saved.getJSONObject(i)
            installed.add(entry.keys().asSequence().associateWith { entry.getString(it) })
        }
        info = nativeSelect("")
        builtinDevices = nativeDevices()
        val path = prefs.getString("selected", "") ?: ""
        if (prefs.getBoolean("initializing", false)) {
            fallback("Previous plugin initialization did not finish. Built-in backend restored.")
        } else if (path.isNotEmpty()) {
            try {
                validate(File(path))
                val metadata = probe(path)
                // Migrate the previously supported single imported backend.
                if (installed.none { it["id"] == File(path).nameWithoutExtension }) {
                    installed.add(record(path, metadata, prefs.getString("file_name", File(path).name) ?: File(path).name))
                    saveCatalog()
                }
                activate(path)
            }
            catch (e: Exception) { fallback(e.message ?: "Plugin initialization failed") }
        } else {
            info = nativeSelect("")
        }
        initialized = true
    }

    fun beginModelLoad() {
        if (selected.isNotEmpty()) check(prefs.edit().putBoolean("initializing", true).commit())
    }
    fun endModelLoad() { prefs.edit().putBoolean("initializing", false).commit() }
    fun isExternal() = selected.isNotEmpty()

    fun fallback(message: String) {
        selected = ""
        status = if (message.contains("Incompatible:")) "Incompatible" else "Failed"
        error = "$message Using built-in backend."
        // Persist fallback before calling any native code, preventing restart loops.
        save()
        endModelLoad()
        info = nativeSelect("")
    }

    private fun activate(path: String, persist: Boolean = true) {
        check(prefs.edit().putBoolean("initializing", true).commit())
        info = nativeSelect(path)
        selected = path; status = "Loaded"; error = ""
        android.util.Log.i("JLexaPlugin", "Loaded ${info[0]} from ${if (path.isEmpty()) "bundled library" else path}")
        if (persist) save()
        endModelLoad()
    }

    suspend fun useBuiltin() = lock.withLock {
        activate("")
    }

    suspend fun selectPlugin(id: String, persist: Boolean = true) = lock.withLock {
        if (id.isEmpty()) { activate("", persist); return@withLock }
        val entry = installed.find { it["id"] == id } ?: error("Backend is no longer installed")
        val file = File(directory, "${entry.getValue("id")}.so")
        validate(file)
        if (persist) probe(file.absolutePath)
        activate(file.absolutePath, persist)
    }

    suspend fun deletePlugin(id: String) = lock.withLock {
        check(id != selectedId()) { "Switch to a built-in backend before deleting the active backend" }
        val entry = installed.find { it["id"] == id } ?: error("Backend is no longer installed")
        val file = File(directory, "${entry.getValue("id")}.so")
        check(file.canonicalFile.parentFile == directory.canonicalFile) { "Invalid private plugin path" }
        check(!file.exists() || file.delete()) { "Could not delete imported backend" }
        installed.remove(entry)
        saveCatalog()
    }

    private fun validate(file: File) {
        require(file.canonicalFile.parentFile == directory.canonicalFile && file.isFile) {
            "Failed: plugin must be in JLexa private storage."
        }
        RandomAccessFile(file, "r").use { f ->
            val h = ByteArray(64)
            if (f.length() < 64) throw IllegalArgumentException("Incompatible: invalid .so (truncated ELF header).")
            f.readFully(h)
            require(h[0] == 0x7f.toByte() && h[1] == 69.toByte() && h[2] == 76.toByte() && h[3] == 70.toByte()) {
                "Incompatible: invalid .so (not an ELF file)."
            }
            require(h[4] == 2.toByte() && h[5] == 1.toByte() && h[18] == 183.toByte() && h[19] == 0.toByte()) {
                "Incompatible: expected arm64-v8a; this library targets a different ABI."
            }
            require(h[16] == 3.toByte() && h[17] == 0.toByte()) { "Incompatible: expected an ELF shared library." }
        }
        require(Build.SUPPORTED_ABIS.contains("arm64-v8a") && Process.is64Bit()) {
            "Incompatible: external plugins require an arm64-v8a app/device."
        }
        check(file.setReadOnly()) { "Failed: could not make plugin read-only." }
        val mode = android.system.Os.stat(file.absolutePath).st_mode
        check(mode and 146 == 0) { "Failed: plugin still has write permissions." }
        android.util.Log.i("JLexaPlugin", "Validated private ARM64 plugin ${file.name}, mode=${Integer.toOctalString(mode and 511)}")
    }

    suspend fun importPlugin(): Map<String, Any> = lock.withLock {
        val activity = context as? Activity ?: error("File picker requires an Activity")
        val pending = CompletableDeferred<Uri?>()
        picker = pending
        val uri = try {
            withContext(Dispatchers.Main) {
                activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE); type = "*/*"
                }, PICK_PLUGIN)
            }
            pending.await()
        } finally { picker = null }
        if (uri == null) return@withLock snapshot()
        var candidate: File? = null
        try {
            val name = context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            } ?: "plugin.so"
            require(name.endsWith(".so", ignoreCase = true)) { "Incompatible: select a .so file." }
            val file = File(directory, "${UUID.randomUUID()}.so")
            candidate = file
            context.contentResolver.openInputStream(uri).use { input ->
                checkNotNull(input) { "Could not open selected file" }
                FileOutputStream(file).use { output ->
                    // Mark read-only while retaining our already-open write descriptor.
                    check(file.setReadOnly()) { "Could not make plugin read-only" }
                    val buffer = ByteArray(65536); var total = 0L
                    while (true) {
                        val count = input.read(buffer); if (count < 0) break
                        total += count
                        require(total <= 512L * 1024 * 1024) { "Plugin exceeds 512 MB import limit" }
                        output.write(buffer, 0, count)
                    }
                    output.fd.sync()
                }
            }
            validate(file)
            val metadata = probe(file.absolutePath)
            val entry = record(file.absolutePath, metadata, name)
            installed.add(entry)
            try { saveCatalog() } catch (e: Exception) { installed.remove(entry); throw e }
        } catch (e: Exception) {
            candidate?.delete()
            throw IllegalStateException(e.message ?: "Plugin import failed", e)
        }
        snapshot()
    }

    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_PLUGIN) return false
        picker?.complete(if (resultCode == Activity.RESULT_OK) data?.data else null)
        return true
    }

    private suspend fun probe(path: String): Array<String> = withContext(Dispatchers.Main) {
        var metadata: Array<String>? = null
        val completed = CompletableDeferred<String>()
        val reply = Messenger(Handler(Looper.getMainLooper()) { msg ->
            metadata = msg.data.getStringArray("info")
            completed.complete(msg.data.getString("error", "")); true
        })
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                try {
                    Messenger(binder).send(Message.obtain(null, 1).apply {
                        data = Bundle().apply { putString("path", path) }; replyTo = reply
                    })
                } catch (e: Exception) { completed.complete("Failed: ${e.message}") }
            }
            override fun onServiceDisconnected(name: ComponentName) { completed.complete("Failed: plugin crashed during initialization.") }
            override fun onBindingDied(name: ComponentName) { completed.complete("Failed: plugin probe process died.") }
            override fun onNullBinding(name: ComponentName) { completed.complete("Failed: plugin probe could not start.") }
        }
        check(context.bindService(Intent(context, PluginProbeService::class.java), connection, Context.BIND_AUTO_CREATE)) {
            "Failed: could not start plugin probe."
        }
        val failure = try { withTimeout(20000) { completed.await() } }
            catch (_: TimeoutCancellationException) { "Failed: plugin initialization timed out." }
            finally { context.unbindService(connection) }
        if (failure.isNotEmpty()) throw IllegalStateException(failure)
        requireNotNull(metadata?.takeIf { it.size == 4 }) { "Incompatible: plugin metadata missing" }
    }
}
