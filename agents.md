# JLexa Agent Session Log

## Standard Release Output Path
All signed release builds must be placed at this fixed, single location at the repository root:
- **`release/app-release.apk`** (`c:\Users\jiefei\Desktop\devel\JLexa\release\app-release.apk`)

## Instructions for Future Agents
At the end of every agent session after completing work:
1. Run static analysis: `flutter analyze` from `app/` and ensure zero errors or warnings.
2. Run the test suite: `flutter test --concurrency=1` from `app/`.
3. Build the signed release APK: `flutter build apk --release` from `app/`. Ensure signing is configured via `app/android/key.properties`.
4. Verify APK signature:
   `apksigner verify --verbose --print-certs "app/build/app/outputs/flutter-apk/app-release.apk"`
5. Copy the signed release artifact to the fixed path:
   `Copy-Item -Path "app/build/app/outputs/flutter-apk/app-release.apk" -Destination "release/app-release.apk" -Force`
6. Remove any obsolete/temporary APKs outside of the release path.
7. Append a new entry to this file (`agents.md`) documenting the session date, summary of work done, test results, release build artifact status, and signing verification digest.

## Device Installation & Hot Reload Protocol
- **ADB APK Full Installation**: On physical test devices (e.g., MagicOS / Android OEM security systems), ADB cannot perform fully unattended / silent APK installations without physical on-screen user authorization. When executing an `adb` APK installation (`adb install` or `adb shell pm install`), the agent **must stop outputting and explicitly notify the user to tap "Continue" and "Install" on the phone screen**.
- **Incremental Flutter Updates / Hot Reload**: For incremental Flutter Dart changes (UI updates, business logic, bug fixes), use Flutter hot reload / hot restart (`flutter run` with hot reload) instead of performing a full package re-installation. Hot reload updates code directly without triggering OEM package installer security dialogs and requires no user confirmation.

---

## Session: 2026-09-01
- **Focus**: Functional correctness & bug-fix pass on local model management, lifecycle ownership, transactional rollbacks, download validation, cancellation semantics, Dictionary AI state handling, and signed release APK build pipeline.
- **Bugs Fixed**:
  1. *ModelManager Lifecycle Ownership*: Hoisted `ModelManager` to root in `main.dart` and passed down through `MainScaffold` and `SettingsScreen`. `SettingsController` now distinguishes between externally injected vs. owned manager to prevent disposal during navigation.
  2. *Download Validation & Cleanup*: `ModelStorage.atomicFinalizeDownload` now strictly enforces exact byte size match against `expectedSizeBytes > 0`. Corrupted or partial `.part` files are deleted on size mismatch with `ModelValidationException` thrown while keeping valid existing models intact. `cleanStalePartFiles` protects active download files.
  3. *Transactional Model Switch with Rollback*: `ModelManager.loadModel` now backs up previously loaded model paths for both LLM and Whisper engines. If loading the new model fails, it automatically reloads the previous model and surfaces an informative error.
  4. *Typed Download Cancellation*: Introduced `ModelDownloadCancelledException`. Downloader cancels active requests cleanly and removes temporary `.part` files without treating user cancellation as an error. `deleteModel` safely cancels any in-progress download prior to deleting model assets.
  5. *Dictionary AI State Invalidation*: Tab switches during in-progress AI generations reset partial chunk text and increment `_aiGeneration` to prevent stale streaming text from poisoning tab state upon switching back.
  6. *Release Keystore & Signing Pipeline*: Fixed BOM and key sanitization in `app/android/app/build.gradle.kts` for `key.properties` loading. Ensured release buildType binds to release signingConfig with keystore validation.
- **Test Suite**:
  - Added 27 new tests across `model_storage_test.dart`, `model_manager_test.dart`, `settings_controller_test.dart`, and `dictionary_controller_test.dart`.
  - Result: `129 passed`, `0 failed`.
- **Static Analysis**:
  - `flutter analyze` -> No issues found!
- **Fixed Signed Release APK Location**:
  - Path: `release/app-release.apk` (50.1 MB)
  - Signer SHA-256: `68:90:D4:8A:B8:F1:B2:60:83:92:FA:D0:F9:DF:FA:D9:D7:7F:12:57:55:4B:17:E2:A8:66:A7:D2:E7:D1:16:DA`
  - APK Signature Scheme v2: `true` (Verified)
  - Result: Success

---

## Session: 2026-09-02
- **Focus**: llama.cpp runtime backend configuration system (Auto, CPU, Vulkan, OpenCL, availability checks), startup restoration of LLM and Whisper models, offline English dictionary SQLite database with AI fallback decoupling, and hardening Android native inference.
- **Key Enhancements & Robustness Fixes**:
  1. *llama.cpp Runtime & Hardware Acceleration Backend Selection*:
     - Native C++ bridge (`jlexa_llama_bridge.cpp`) and JNI bindings (`jlexa_jni.cpp`) now enumerate available ggml backend devices (Vulkan GPU, OpenCL GPU, CPU).
     - Backends not actually available/compiled are accurately reported so unavailable backends are never advertised or enabled.
     - Auto-selection resolves to Vulkan GPU when available, falling back safely to CPU.
     - Extended `LlamaRuntimeSettings` with `threads`, `contextLength`, `gpuLayers`, `batchSize`, `microBatchSize`, and `flashAttention`.
     - Settings are persisted in SQLite `app_settings` and automatically restored upon next launch.
     - Added real-time active runtime status card displaying the active hardware device, context window, threads, and batch sizes.
  2. *Automatic Startup Restoration of LLM & Whisper Models*:
     - `AiService.initialize()` restores previously selected LLM and Whisper models with independent try-catch isolation so that a failure in one model never impairs the other.
     - Stale or missing model paths are recorded in separate restoration errors without crashing or blocking startup.
  3. *Offline English Dictionary SQLite Database & Decoupled AI Fallback*:
     - Implemented local SQLite `offline_dictionary` table with index on `word` and curated bilingual dataset (Princeton WordNet license documented).
     - Decoupled `DictionaryController` and `DictionaryScreen` so offline lookup misses gracefully allow AI Translation and AI Contextual Explanation without blocking or error state.
     - Clear visual attribution distinguishing curated offline entries from local AI generated content.
  4. *Android Native-Inference Hardening & Automated Testing*:
     - Fixed llama.cpp graph node overflow crash by chunking prompt evaluation by `n_batch` in `jlexa_llama_bridge.cpp`.
     - Added JNI `ExceptionCheck()` guards across callback threads.
     - Added on-device integration tests (`native_inference_test.dart`) and upgraded `scripts/test_android.ps1` with dedicated logcat filters and crash buffer extraction.
- **Test Suite**:
  - 135 unit & widget tests passed (`135 passed`, `0 failed`).
- **Static Analysis**:
  - `flutter analyze` -> `No issues found!` (0 errors, 0 warnings).
- **Fixed Signed Release APK Location**:
  - Path: `release/app-release.apk` (50.3 MB)
  - Signer SHA-256: `68:90:D4:8A:B8:F1:B2:60:83:92:FA:D0:F9:DF:FA:D9:D7:7F:12:57:55:4B:17:E2:A8:66:A7:D2:E7:D1:16:DA`
  - APK Signature Scheme v2: `true` (Verified)
  - Result: Success
---

## Session: 2026-09-06
- **Focus**: Diagnosed and fixed native Android crash during local AI text generation on physical device (`AJTLVB4B05002604` / `PTP-AN00`), hardened JNI exception handling, secured ProGuard / R8 keep rules for native callbacks, and verified live on-device Qwen inference.
- **Root Cause Diagnosed**:
  - In release builds, R8 code shrinking obfuscated and stripped `LlamaBridge$NativeGenerationCallback` methods (`onToken` and `onComplete`) because no ProGuard keep rules protected them.
  - When native C++ code in `jlexa_jni.cpp` attempted `env->GetMethodID(callbackClass, "onToken", "(Ljava/lang/String;)V")`, Android ART threw `java.lang.NoSuchMethodError`.
  - The native JNI code lacked `env->ExceptionCheck()` and attempted subsequent JNI calls with an unhandled pending exception, triggering ART's `art::Thread::AssertNoPendingExceptionForNewException` abort (`SIGABRT`, signal 6).
  - A similar latent vulnerability existed for `WhisperBridge$NativeProgressCallback` (`onProgress`).
- **Fixes Applied**:
  1. *ProGuard / R8 Rules (`app/android/app/proguard-rules.pro`)*:
     - Configured keep rules to preserve native bridges, callback interfaces, implementations, and methods (`com.example.local_ai_app.LlamaBridge**`, `com.example.local_ai_app.WhisperBridge**`, and Flutter platform channel classes).
     - Linked `proguard-rules.pro` via `getDefaultProguardFile("proguard-android-optimize.txt")` in `app/android/app/build.gradle.kts`.
  2. *Bridge Class Protection & Annotations*:
     - Decorated `LlamaBridge`, `WhisperBridge`, `NativeGenerationCallback`, and `NativeProgressCallback` with `@androidx.annotation.Keep`.
     - Replaced anonymous inner classes with explicit `@Keep class GenerationCallback` and `@Keep class ProgressCallback` to ensure predictable, non-obfuscated method signatures across all build variants.
  3. *Native JNI Hardening (`app/android/app/src/main/cpp/jlexa_jni.cpp`)*:
     - Added strict `env->ExceptionCheck()` checks and `env->ExceptionClear()` guards around all callback method resolution and invocations.
     - Added local reference frame management (`PushLocalFrame`/`PopLocalFrame`) and null checks for strings and method IDs.
  4. *Integration Verification*:
     - Upgraded `native_inference_test.dart` to verify on-device model discovery and repeated sequential generations.
- **Verification on Physical Device (`AJTLVB4B05002604` / `PTP_AN00`)**:
  - Installed signed release APK in-place preserving pre-downloaded Qwen model data.
  - Verified local AI generation on device in Tab 5 ("Ask AI"):
    - Generation 1: Example question answered in English with streaming tokens.
    - Generation 2: Contextual query answered in Chinese without reload or memory leak.
    - Tab switch to Tab 2 ("Dictionary") and back to Tab 5: Session state and history preserved.
    - Generation 3: Custom user prompt executed and answered successfully.
    - Process stability: PID remained continuous across all interactions with 0 native aborts.
- **Static Analysis**:
  - `flutter analyze` -> `No issues found!` (0 errors, 0 warnings).
- **Test Suite**:
  - `flutter test --concurrency=1` -> `135 passed, 0 failed`.
- **Fixed Signed Release APK Location**:
  - Path: `release/app-release.apk` (50.5 MB)
  - Signer SHA-256: `68:90:D4:8A:B8:F1:B2:60:83:92:FA:D0:F9:DF:FA:D9:D7:7F:12:57:55:4B:17:E2:A8:66:A7:D2:E7:D1:16:DA`
  - APK Signature Scheme v2: `true` (Verified)
  - Result: Success
