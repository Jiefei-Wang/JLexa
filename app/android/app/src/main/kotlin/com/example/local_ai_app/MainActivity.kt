package com.example.local_ai_app

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val safStorageBridge by lazy { SafStorageBridge(this) }
    private val whisperBridge by lazy { WhisperBridge(this) }
    private val llamaBridge by lazy { LlamaBridge(this) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Register SAF Storage method channel and download stream channel
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.jlexa.app/saf_storage"
        ).setMethodCallHandler(safStorageBridge)

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.jlexa.app/saf_download_stream"
        ).setStreamHandler(safStorageBridge)

        // Register Whisper method channel and progress stream channel
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.jlexa.app/whisper"
        ).setMethodCallHandler(whisperBridge)

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.jlexa.app/whisper_stream"
        ).setStreamHandler(whisperBridge)

        // Register Llama method channel and stream channel
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.jlexa.app/llama"
        ).setMethodCallHandler(llamaBridge)

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.jlexa.app/llama_stream"
        ).setStreamHandler(llamaBridge)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (!safStorageBridge.handleActivityResult(requestCode, resultCode, data)) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        safStorageBridge.cleanUp()
        whisperBridge.cleanUp()
        llamaBridge.cleanUp()
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
