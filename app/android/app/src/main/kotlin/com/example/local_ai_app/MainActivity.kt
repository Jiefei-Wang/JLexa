package com.example.local_ai_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val whisperBridge = WhisperBridge()
    private val llamaBridge = LlamaBridge()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        whisperBridge.cleanUp()
        llamaBridge.cleanUp()
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
