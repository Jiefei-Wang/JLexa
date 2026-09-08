package com.example.local_ai_app

import android.app.Service
import android.content.Intent
import android.os.*

/** Disposable process: constructors, ABI inspection and create/destroy cannot crash the UI. */
open class PluginProbeService : Service() {
    override fun onBind(intent: Intent): IBinder = Messenger(Handler(Looper.getMainLooper()) { msg ->
        val path = msg.data.getString("path") ?: ""
        val reply = msg.replyTo
        val speech = msg.data.getBoolean("speech", false)
        Thread {
            // A hung plugin must not leave a process (or a future probe) stuck indefinitely.
            val watchdog = Handler(Looper.getMainLooper())
            val kill = Runnable { Process.killProcess(Process.myPid()) }
            watchdog.postDelayed(kill, 18000)
            var failure = ""
            var metadata: Array<String>? = null
            try {
                System.loadLibrary("jlexa_native")
                val plugins = BackendPlugins(this, speech)
                metadata = plugins.selectNative(path)
                plugins.selectNative("") // Exercise destruction before reporting success.
            } catch (e: Throwable) { failure = e.message ?: "Plugin initialization failed" }
            try { reply.send(Message.obtain(null, 1).apply { data = Bundle().apply { putString("error", failure); putStringArray("info", metadata) } }) }
            finally { watchdog.postDelayed(kill, 200) }
        }.start()
        true
    }).binder
}

// Independent disposable process: probing speech cannot kill an LLM probe.
class SpeechPluginProbeService : PluginProbeService()
