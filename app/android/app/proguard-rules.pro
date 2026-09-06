# Flutter rules
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Keep native methods and their enclosing classes
-keepclasseswithmembernames class * {
    native <methods>;
}

# Preserve all JLexa platform channels, bridges, callbacks, and decoders
-keep class com.example.local_ai_app.** { *; }
-keepclassmembers class com.example.local_ai_app.** { *; }
-keep interface com.example.local_ai_app.** { *; }

# Explicitly keep callback interfaces and their implementors
-keep interface com.example.local_ai_app.LlamaBridge$NativeGenerationCallback {
    public *;
}
-keep class * implements com.example.local_ai_app.LlamaBridge$NativeGenerationCallback {
    public *;
}

-keep interface com.example.local_ai_app.WhisperBridge$NativeProgressCallback {
    public *;
}
-keep class * implements com.example.local_ai_app.WhisperBridge$NativeProgressCallback {
    public *;
}

# Preserve androidx @Keep annotations
-keep @androidx.annotation.Keep class * { *; }
-keepclassmembers class * {
    @androidx.annotation.Keep *;
}

# Flutter deferred components play core dontwarn
-dontwarn com.google.android.play.core.**
