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
8. Commit and push: Every time when you finish a comprehensive change from user's prompt, commit the changes with a clear, descriptive message and push to the remote repository (`git push`).

## Device Installation & Hot Reload Protocol
- **ADB APK Full Installation**: On physical test devices (e.g., MagicOS / Android OEM security systems), ADB cannot perform fully unattended / silent APK installations without physical on-screen user authorization. When executing an `adb` APK installation (`adb install` or `adb shell pm install`), the agent **must stop outputting and explicitly notify the user to tap "Continue" and "Install" on the phone screen**.
- **Incremental Flutter Updates / Hot Reload**: For incremental Flutter Dart changes (UI updates, business logic, bug fixes), use Flutter hot reload / hot restart (`flutter run` with hot reload) instead of performing a full package re-installation. Hot reload updates code directly without triggering OEM package installer security dialogs and requires no user confirmation.

---

## Session: 2026-09-06 (Pass 3)
- **Focus**: Completed the audio-cut/repeater correctness implementation and fixed Android SAF model downloads, resumability, finalization, native content-URI model loading, and startup restoration.
- **Key Fixes**:
  1. Added revision-safe independent cut editing, symmetric overlap compression, strict half-open active ranges, atomic persistence, real looping, adaptive VAD, and waveform-based boundary controls.
  2. Hardened AI/transcription ownership and cancellation, prevented stale cross-lesson updates, added manual repeater explanations, and improved waveform cache identity and cleanup.
  3. Fixed SAF downloads by retaining resumable `.part` files, using HTTP Range requests, extending read timeouts, validating exact sizes, and falling back to stream-copy finalization when a document provider cannot rename files.
  4. Added detailed Android platform error reporting and seven-day stale-part cleanup without deleting active/recent partial downloads.
  5. Added native `FILE*` loaders for llama.cpp and whisper.cpp so `/proc/self/fd/<fd>` SAF documents remain loadable for the full model lifetime.
  6. Fixed startup restoration of persisted `content://` model paths; native ContentResolver loading now performs the authoritative validation instead of `dart:io File.exists()` rejecting valid SAF URIs.
  7. Compiled and exposed the Vulkan backend, reported OpenCL accurately as not compiled, and caught native Vulkan driver exceptions so unsupported compute pipelines return an error instead of terminating the process. CPU remains the verified safe backend on the tested Honor device.
- **Physical Device Verification**:
  - Honor PTP-AN00: downloaded Qwen2.5 1.5B (1,117,320,736 bytes) into the selected SAF folder, verified SHA-256 `6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e`, loaded it through a content URI, and completed native CPU generation.
  - Pixel 6 (`25311FDF6004PR`, Android 16): installed the signed release through a staged ADB push plus `pm install`; app launched successfully as PID 12801 with ABI `arm64-v8a`, minSdk 28, and targetSdk 36.
- **Static Analysis**:
  - `flutter analyze` -> `No issues found!` (0 errors, 0 warnings).
- **Test Suite**:
  - `flutter test --concurrency=1` -> `153 passed, 0 failed`.
- **Fixed Signed Release APK Location**:
  - Path: `release/app-release.apk` (88,508,239 bytes)
  - APK SHA-256: `7D0EBCFF5A7CD91CE3B839F066D8CFFEF2D198D3603555CAF09BF4F5C815901D`
  - Signer SHA-256: `68:90:D4:8A:B8:F1:B2:60:83:92:FA:D0:F9:DF:FA:D9:D7:7F:12:57:55:4B:17:E2:A8:66:A7:D2:E7:D1:16:DA`
  - APK Signature Scheme v2: `true` (Verified)
  - Result: Success

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

---

## Session: 2026-09-06 (Pass 2)
- **Focus**: Feature 1: Unified Dictionary AI Answer (Word & Phrase structured responses, fallback parser, 2-tab Dictionary UX, vocabulary snapshots); Feature 2: Persistent user-selected model storage folder via SAF (`ACTION_OPEN_DOCUMENT_TREE`, `takePersistableUriPermission`, DocumentFile, `/proc/self/fd/<fd>` native loading, auto-scanning custom models in `llm/` and `whisper/`, catalog gating, folder change safe model unloading), JNI exception clearing hardening.
- **Implemented & Hardened**:
  1. *Unified Dictionary AI Answer*:
     - Sealed hierarchy `DictionaryAiAnswer` (`DictionaryWordAnswer` with senses + `DictionaryPhraseAnswer` with explanation).
     - Robust parser in `dictionary_ai_parser.dart` handling JSON parsing, markdown code fences, POS line fallbacks, and phrase text.
     - Prompt builder enforces strict JSON schema generation for dictionary queries.
     - Dictionary UI consolidated from 3 tabs into 2 tabs: "Dictionary" and "AI Answer".
     - Removed redundant/duplicate AI buttons on offline dictionary misses (clean "No entry found.").
     - Refactored vocabulary snapshotting in `DictionaryController` to snapshot structured word senses and phrase explanations.
  2. *User-Selected Persistent Model Storage Folder (Android SAF + Desktop/Test FileSystem Backend)*:
     - Implemented `ModelStorageBackend` interface with `AndroidSafModelStorageBackend` and `FileSystemModelStorageBackend`.
     - Platform channel `com.jlexa.app/saf_storage` and event channel `com.jlexa.app/saf_download_stream` in Kotlin (`SafStorageBridge.kt`).
     - Persistent folder selection using `Intent.ACTION_OPEN_DOCUMENT_TREE` + `takePersistableUriPermission` stored in SharedPreferences.
     - Automatically creates and manages `<folder>/llm/` and `<folder>/whisper/` subdirectories.
     - Auto-scans and lists custom `.gguf` and Whisper model files placed in those subfolders without requiring manual import buttons.
     - Replaced manual "import file" buttons in Settings with an informative Custom Models card.
     - Model catalog and downloads gated on storage configuration; unconfigured state prompts user to select a folder.
     - Implemented safe folder switching in `ModelManager`: unloads active models if they do not exist in the newly selected folder.
  3. *Native Android Model Loading via `/proc/self/fd/<fd>`*:
     - `LlamaBridge.kt` and `WhisperBridge.kt` resolve `content://` URIs by opening `ParcelFileDescriptor` via ContentResolver and passing `/proc/self/fd/${pfd.fd}` to native C++ loaders.
     - Holds `ParcelFileDescriptor` reference for the entire lifetime of the loaded model and closes it cleanly upon model unloading or engine cleanup.
  4. *JNI Hardening (`app/android/app/src/main/cpp/jlexa_jni.cpp`)*:
     - Added reusable `clearPendingException` utility and guarded JNI callback lookups and method invocations.
- **Test Suite**:
  - `flutter test --concurrency=1` -> `145 passed, 0 failed` (10 new unit & widget tests added covering structured AI parsing, phrase vocabulary saving, unconfigured catalog gating, custom model auto-detection, and folder switching).
- **Static Analysis**:
  - `flutter analyze` -> `No issues found!` (0 errors, 0 warnings).
- **Fixed Signed Release APK Location**:
  - Path: `release/app-release.apk` (49.8 MB / 52,217,811 bytes)
  - Signer SHA-256: `68:90:D4:8A:B8:F1:B2:60:83:92:FA:D0:F9:DF:FA:D9:D7:7F:12:57:55:4B:17:E2:A8:66:A7:D2:E7:D1:16:DA`
  - APK Signature Scheme v2: `true` (Verified)
  - Result: Success

---

## Session: 2026-09-06 (Pixel 6 Device Validation Pass)
- **Focus**: End-to-end validation on Google Pixel 6 (`25311FDF6004PR`, Android 16), including SAF model downloads, CPU/Vulkan generation, WAV/MP3 VAD and Whisper transcription, repeat-one playback, persisted per-cut transcript display, and Auto transcription cancellation races.
- **Bugs Fixed**:
  1. *Auto Transcription Cut-Switch Race*: A cancelled Whisper request could return after the active cut changed, persist stale text into the old cut, and leave the controller permanently in `cancelling`. Stale operation results are now rejected before persistence, the owning request always releases the transcription slot, and Auto waits for native terminal completion before transcribing the latest cut.
  2. *Persisted Transcript Visibility*: Saved transcripts were hidden after reopening a lesson, switching cuts with Auto disabled, or disabling Auto. Valid persisted text is now restored and follows the active cut independently of the currently loaded Whisper model.
  3. *Repeat-One Observability*: Added concise release-mode loop boundary logging to prove that playback seeks to the selected cut start and resumes after every cut end.
- **Physical Device Verification**:
  - In-app SAF download completed for Qwen2.5 0.5B (`491,400,032` bytes; SHA-256 `74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db`) and Whisper Tiny.
  - CPU and Vulkan (`Mali-G78`) each loaded the real GGUF and produced coherent answers without process restart or native abort; Auto was restored to Vulkan after testing.
  - A known English WAV and MP3 fixture with leading/trailing silence produced real VAD cuts. Manual per-cut Whisper returned `This is a real speech recognition test`; MP3 Auto mode returned `Hello`; internal control tokens were absent.
  - Repeat-one completed four consecutive cycles for cut bounds `2652-5049 ms`, seeking back to `2652 ms` each time.
  - Manual AI sentence explanation generated only after tapping **Generate Explanation**. Existing app data, audio lessons, and model files were preserved across release upgrades.
- **Test Suite**:
  - Added 3 regression tests for invalidated-request cleanup, Auto cut-switch serialization, and persisted transcript visibility.
  - `flutter test --concurrency=1` -> `156 passed`, `0 failed`.
- **Static Analysis**:
  - `flutter analyze` -> `No issues found!` (0 errors, 0 warnings).
- **Fixed Signed Release APK Location**:
  - Path: `release/app-release.apk` (88,508,239 bytes)
  - APK SHA-256: `277BE1AC3CFC624FA0084C8C0C09BDD327004B3F75360580FD0BC157B7CB956A`
  - Signer SHA-256: `68:90:D4:8A:B8:F1:B2:60:83:92:FA:D0:F9:DF:FA:D9:D7:7F:12:57:55:4B:17:E2:A8:66:A7:D2:E7:D1:16:DA`
  - APK Signature Scheme v2: `true` (Verified)
  - Pixel 6 installation: Success (`pm install -r`, data preserved; final PID `15562`).

---

## Session: 2026-09-06 (Split Segment at Playhead)
- **Focus**: Changed the waveform **Add cut** action so pressing it inside an existing segment splits that segment at the current playback position and explicitly selects the left result.
- **Implementation**:
  - Added an atomic, revision-checked `CutEditor.split` operation that preserves the original ID on the left, creates a unique ID on the right, maintains half-open non-overlapping intervals, and invalidates transcript metadata on both changed cuts.
  - Kept the Add button enabled inside an active segment while preserving the existing VAD-based add behavior in gaps.
  - Added a post-split selection override so late/quantized Android decoder position callbacks cannot steal selection from the left cut. The override is released on the next explicit seek, waveform scrub, playback, or previous/next action.
  - Cancels/invalidate any in-flight Whisper transcription and AI explanation before committing the split.
- **Verification**:
  - Added pure split tests for boundaries, uniqueness, ordering, revision changes, and transcript invalidation.
  - Added controller coverage proving a `0-4000 ms` cut split at `2000 ms` becomes `0-2000` and `2000-4000`, with the original left cut selected even after a late boundary callback.
  - Pixel 6 release validation confirmed the Add button remains enabled inside a cut, split persistence succeeds, transcript is invalidated, the left cut remains active, and the process remains stable.
- **Static Analysis**:
  - `flutter analyze` -> `No issues found!`.
- **Test Suite**:
  - `flutter test --concurrency=1` -> `158 passed`, `0 failed`.
- **Fixed Signed Release APK Location**:
  - Path: `release/app-release.apk` (88,508,239 bytes)
  - APK SHA-256: `BC1543F763D35FA9C1A908EEEF19ED31113C8A71DF433AF43007F1CF9B6A7CB5`
  - Signer SHA-256: `68:90:D4:8A:B8:F1:B2:60:83:92:FA:D0:F9:DF:FA:D9:D7:7F:12:57:55:4B:17:E2:A8:66:A7:D2:E7:D1:16:DA`
  - APK Signature Scheme v2: `true` (Verified)
  - Pixel 6 installation: Success (`pm install -r`, data preserved; final PID `20803`).

---

## Session: 2026-09-06 (Comprehensive Pixel 6 UI and Functional QA)
- **Focus**: Exercised dictionary, sentence translation, repeater, transcription, explanations, vocabulary/review, Home navigation, chat, microphone start/stop, and local model settings on Pixel 6 (`25311FDF6004PR`, Android 16). Full findings and limitations: `docs/qa-2026-09-06.md`.
- **Changes**:
  - Added the licensed ECDICT learner subset (57,961 entries), isolated read-only database, reproducible build script, exact-match lookup, literal suggestions, and correct empty search history.
  - Fixed sentence query preservation, narrow/keyboard layouts, AI-only vocabulary saving, stale query/save ownership, and repeated navigation to the same word.
  - Simplified translation/dictionary/explanation prompts, supplied Chinese dictionary context, added native top-k/repetition penalties, and removed duplicate sampler acceptance.
  - Fixed replay after EOF by retaining the source and resetting playback position; guarded loop resumes against a concurrent Pause.
  - Fixed Android system-navigation overlap and long-content layouts in review, chat, settings, and word sheets; added working recent/chat history sheets and AI explanation cancellation/regeneration.
- **Device Results**:
  - Existing SAF models and lessons survived signed upgrades. CPU and Vulkan each generated Chinese translations; final native sampler completed generation without the previous runaway repetition on the tested word.
  - Fresh WAV import produced automatic cuts and Whisper transcripts `Hello` and `This is a real speech recognition test`; manual/Auto MP3 transcription, repeated playback, EOF replay, and saved transcripts were exercised.
  - Completed vocabulary review and tested microphone permission/start-stop, with no supplied microphone speech. Removed the temporary `qa-ui-audio` lesson/file after testing; original lessons and models preserved.
  - Final APK installed successfully with `adb install -r`, launched as PID `24883`; crash buffer empty at verification. Runtime preference restored to Auto.
  - Remaining limitation: Qwen2.5 0.5B still made incorrect word/POS and sentence-meaning claims in some samples. Generation success is not a claim of semantic accuracy. Acoustic pause cuts and Whisper Tiny also require manual correction for difficult audio.
- **Static Analysis**: `flutter analyze` -> `No issues found!` (zero errors/warnings).
- **Tests**: `flutter test --concurrency=1` -> `167 passed`, zero failed.
- **Signed Release**:
  - `flutter build apk --release` succeeded using `app/android/key.properties`.
  - Fixed path: `release/app-release.apk` (93,129,481 bytes).
  - APK SHA-256: `30224C3CADB3A2B953EC42F7CF0E0D3C6DAAF7E289306A42525F8FDB4E693A1B`.
  - Signer SHA-256: `68:90:D4:8A:B8:F1:B2:60:83:92:FA:D0:F9:DF:FA:D9:D7:7F:12:57:55:4B:17:E2:A8:66:A7:D2:E7:D1:16:DA`.
  - `apksigner verify --verbose --print-certs`: Verified, APK Signature Scheme v2 true.
  - Build emits an upstream `flutter_tts` future Kotlin-plugin compatibility warning; current release build succeeds.
  - Automatic approval review rejected deletion of duplicate build-output APKs (`blocked by policy`); these copies remain under `app/build/app/outputs/`. The fixed release artifact is current.

---

## Session: 2026-09-06 (Seven Requested Repeater, Chat, and Back-Navigation Fixes)
- **Focus**: Implemented the seven screenshot/behavior requests and the explicit Auto OFF preference. Details and final release screenshots: `docs/qa-2026-09-06-seven-fixes.md`.
- **Changes**:
  - Aligned cut handles, shading, hit coordinates, and revision-aware drag previews. Inset shading leaves a thin visible gap between touching cuts without altering audio bounds.
  - Anchored waveform aggregation to the file timeline so playback only translates stable amplitude bars. Refined pause merging while preserving silent gaps.
  - Added the Listening three-dot menu with Import audio, Redo segments, and Reset transcripts. Fingerprint matching reopens identical audio with its saved manual edits; an empty saved cut list is also preserved.
  - Auto OFF now hides transcripts on load/cut switch/disable until Transcribe is tapped. Valid caches can be revealed without a loaded model. Edits and resets quiesce in-flight transcription before atomic revision-checked commits; changed cuts lose obsolete transcripts/explanations.
  - Added persistent chat conversations, new chat, history switching, message/conversation deletion, cancellation, and regeneration. Reopening history fetches the latest snapshot, preventing loss of newly streamed tokens. Removed the disclaimer and instructed replies to follow the user's language.
  - Added actual tab history and normal route popping; only Home requires a second Back within two seconds to exit. Removed the redundant Listening import FAB and persistent import snackbar action.
- **Device Verification**:
  - Pixel 6 (`25311FDF6004PR`, Android 16): fixed boundary dragging, adjacent-cut white gap, stable scrolling waveforms, same-file edit restoration, reset/redo separation, and Auto OFF cache gating.
  - A 25.967-second WAV produced six speech regions and retained a 6.58-second silent gap. Manual resize/split survived reimport; reset retained bounds, while explicit redo generated fresh segment IDs.
  - Native Whisper returned `Hello` for one short cut. Native chat answered in English, regenerated, cancelled, switched/deleted history, and restored its saved conversation across signed release upgrade.
  - Physical Back verified Settings -> Home and Study -> Dictionary -> Home, followed by the double-back exit. Final release also verified menu actions, split rendering, chat generation, and deleting the last question/answer.
  - Final signed upgrade succeeded with `adb install -r`; PID `28599`, crash buffer empty. Temporary QA lesson/source audio and conversations were removed after validation; original lessons and models retained.
- **Static Analysis**: `flutter analyze` -> `No issues found!` (zero errors/warnings).
- **Tests**: `flutter test --concurrency=1` -> `171 passed`, zero failed. Coverage includes waveform geometry/stability, persistence/reset behavior, Chinese chat prompt and cancellation ownership, stale history snapshots, and back navigation.
- **Signed Release**:
  - `flutter build apk --release` succeeded using `app/android/key.properties`; temporary debug-signing changes were removed before the build.
  - Fixed path: `release/app-release.apk` (93,260,625 bytes).
  - APK SHA-256: `27B29C03814E01B36EF3C8E2FFE7EB022DDD51D990D4F14319D6F48B2E731A8C`.
  - Signer SHA-256: `68:90:D4:8A:B8:F1:B2:60:83:92:FA:D0:F9:DF:FA:D9:D7:7F:12:57:55:4B:17:E2:A8:66:A7:D2:E7:D1:16:DA`.
  - `apksigner verify --verbose --print-certs`: Verified, APK Signature Scheme v2 true.
  - Existing upstream `flutter_tts` future Kotlin compatibility warning remains; the release build succeeds.
  - Prior automatic approval rejection still blocks deletion of duplicate APK build outputs. It was not bypassed; the fixed release artifact is current.

---

## Session: 2026-09-06 (Conservative Segmentation on Supplied TED Audio)
- **Focus**: Fixed clipped quiet/rapid sentence openings and excessive splitting at ordinary pauses using the supplied 16:45 TED MP3. Detailed evidence: `docs/qa-2026-09-06-conservative-segmentation.md`.
- **Changes**:
  - Removed display amplitude floors from Android and Dart PCM analysis; v4 peak caches re-extract raw energy while preserving saved manual cuts.
  - Merged raw pauses up to 650 ms, added 400 ms leading and 250 ms trailing context, and retained long silent gaps without overlapping adjacent cuts.
  - Longer phrases split only at a meaningful internal pause; uninterrupted speech is never cut at an arbitrary timer boundary.
  - Kept the waveform preparation indicator visible until initial segmentation finishes, preventing a false no-speech message during long-file analysis.
  - Removed the redundant blocking output-buffer drain wait in Android PCM decoding, reducing preparation delay before per-cut Whisper recognition.
- **Verification**:
  - Full supplied-file envelope audit: 263 -> 139 cuts; median cut duration 1.86 -> 4.451 seconds. The reaction-question interval expanded to 25.999–29.250 seconds on the host envelope.
  - Pixel 6 (`25311FDF6004PR`, Android 16) recognized the complete question: `So what would be your reaction to ideas like that?`.
  - Final signed upgrade succeeded, preserving existing lessons/models and the new `ted-career-safety` lesson, cuts, position, and cache. Auto OFF hid cached text on reopen until Transcribe was tapped. Final process PID: `30766`.
  - Added real-envelope and synthetic regression coverage for quiet onsets/tails, hesitation merging, retained silence, valid bounds, no arbitrary timed cuts, cache migration, and loading UI with/without saved cuts.
  - Final-build uncached native Whisper returned `Do you have children?`; full-MP3 decoding took approximately 128 seconds versus roughly ten minutes before the drain fix. PID remained `30766`, with an empty app crash buffer.
- **Static Analysis**: `flutter analyze` -> `No issues found!` (zero errors/warnings).
- **Tests**: `flutter test --concurrency=1` -> `178 passed`, zero failed.
- **Signed Release**:
  - `flutter build apk --release` succeeded using `app/android/key.properties`.
  - Fixed path: `release/app-release.apk` (93,260,625 bytes).
  - APK SHA-256: `84B8C6228036A2B0D4F04055CF6D27CB2422593CA5304C84DEB22BE21E3EC9F9`.
  - Signer SHA-256: `68:90:D4:8A:B8:F1:B2:60:83:92:FA:D0:F9:DF:FA:D9:D7:7F:12:57:55:4B:17:E2:A8:66:A7:D2:E7:D1:16:DA`.
  - `apksigner verify --verbose --print-certs`: Verified, APK Signature Scheme v2 true.
  - Existing upstream flutter_tts future Kotlin compatibility warning remains; the release build succeeds. Prior blocked APK-output deletion was not retried or bypassed.
- **Limits**: Acoustic cuts can still require manual correction around noise/laughter or linguistic pauses. Existing saved cuts change only through explicit Redo segments. Whisper recognizes a selected cut after full-source PCM preparation.

---

## Session: 2026-09-06 (Repeater Actions and Honor Model/AI Corrections)
- **Focus**: Completed five requested changes: replay control, explicit boundary editing, inline transcription progress, missing model inventory, and PTP_AN00 nonsensical AI output. Evidence: `docs/qa-2026-09-06-repeater-and-honor-ai.md` and `docs/native-cpu-regression.md`.
- **Changes**:
  - Added Replay between Next and Repeat; it restarts the selected cut without toggling looping, including post-split left-cut selection.
  - Added a highlighted Edit toggle before Add. Boundaries are locked by default; waveform seeking remains available. Switching lessons resets editing.
  - Moved transcription spinner/available percentage into Transcribe, retained cancellation and error reporting, and removed the top Whisper status panel.
  - Reconciled model inventory with loaded/configured paths, including legacy private storage and SAF metadata. Refreshes on Settings entry, preserves prior rows on scan errors, and displays loaded models even without a newly configured folder.
  - Fixed CPU mode accidentally enabling Vulkan operation offload. Native CPU loading now supplies an empty accelerator list and disables operation/KQV offloading; GPU selections retain their chosen device.
- **Verification**:
  - Pixel 6 (`25311FDF6004PR`, PID `31723`): locked/on/off boundary dragging, replay seeking/playback without changing Repeat, inline native Whisper progress and complete reaction-question transcription. Temporary QA lesson/source removed; existing lessons/models retained. Crash buffer empty.
  - Honor PTP_AN00 (PID `13889`): final Settings shows Whisper Tiny (English), 74.1 MB, LOADED, outside the selected folder; Qwen2.5 1.5B is also LOADED. Fresh chat now gives related explanations and `早上好。`; crash buffer empty.
  - Controlled native comparison using identical verified Qwen model bytes and deterministic settings: broken hybrid path produced unrelated text for 2+2; corrected CPU returned `4`, correct morning translation, and relevant say/tell prose. Final release library passes `native/tests/llama_cpu_smoke.cpp`, including descriptor loading; native diagnostics show one CPU backend/graph split.
  - AI model SHA-256 unchanged: `6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e`. The model file was not damaged; unintended GPU computation caused the observed corrupt output. Small-model semantic limitations still apply.
- **Static Analysis**: `flutter analyze` -> `No issues found!` (zero errors/warnings).
- **Tests**: `flutter test --concurrency=1` -> `187 passed`, zero failed; final native CPU smoke test PASS.
- **Signed Release**:
  - `flutter build apk --release` succeeded using `app/android/key.properties`; signed upgrade installed successfully on both phones with data preserved.
  - Fixed path: `release/app-release.apk` (93,326,253 bytes).
  - APK SHA-256: `B0466185951A0A124C41D9A9FE27D432498B7799C06CA3B40AB6514FF61CF4A5`.
  - Signer SHA-256: `68:90:D4:8A:B8:F1:B2:60:83:92:FA:D0:F9:DF:FA:D9:D7:7F:12:57:55:4B:17:E2:A8:66:A7:D2:E7:D1:16:DA`.
  - `apksigner verify --verbose --print-certs`: Verified, APK Signature Scheme v2 true.
  - Existing upstream flutter_tts Kotlin compatibility notice remains; release build succeeds. Prior blocked duplicate APK-output cleanup was not retried or bypassed.

---

## Session: 2026-09-06 (Honor Adreno 830 Vulkan Generation Compatibility)
- **Focus**: Fixed the user's explicit Vulkan `createComputePipeline: ErrorUnknown` failure on PTP_AN00. Diagnosis, controlled variants, reproduction, and limitations: `docs/native-vulkan-regression.md`.
- **Changes**:
  - Added reproducible CMake overlays that leave pinned vendor submodules clean. Q4_K/Q6_K matvec shaders use equivalent 32-bit byte unpacking; Adreno 830 alone receives rolled SPIR-V loops and effective Vulkan batch/microbatch 1. CPU isolation and Mali batch sizes remain unchanged.
  - Fixed the related permanent hang after a failed pipeline compile: cache the failure, clean partially created handles, clear pending, notify waiters, and return the failure on subsequent requests.
  - Made runtime setting changes transactional and serialized. Failed model reload restores the prior actual runtime; rollback failure is visible and clears stale active details. Active generation cannot be interrupted by a settings switch.
  - Settings shows effective batch/microbatch, explains the smaller-batch performance tradeoff, and distinguishes an unloaded model from an active CPU runtime.
- **Native Device Verification**:
  - Honor PTP_AN00: the final release library completed three sequential Vulkan generations on Adreno 830 with batch/microbatch 1, returning `4`, `早上好。`, and relevant say/tell prose. Same-model CPU regression also passed with batch/microbatch 512.
  - Pixel 6: the final release library passed the same Vulkan arithmetic/translation fixture on Mali-G78 with batch/microbatch 512; no Adreno cap applied.
  - A raw llama.cpp fixture deliberately bypassed the app's batch cap to trigger the actual Honor driver failure twice. Both attempts returned `ErrorUnknown` promptly and the context was freed; the previous retry hang did not recur.
  - Native SPIR-V fixture passed device/kernel scoping, control-bit preservation, idempotence, and malformed-input checks. Test sources are under `native/tests/`.
- **Static Analysis**: `flutter analyze` -> `No issues found!` (zero errors/warnings).
- **Tests**: `flutter test --concurrency=1` -> `191 passed`, zero failed; native GPU/CPU/compatibility/retry fixtures passed.
- **Signed Release**:
  - `flutter build apk --release` succeeded using `app/android/key.properties`.
  - Fixed path: `release/app-release.apk` (93,342,637 bytes).
  - APK SHA-256: `0374BF4D86BEA820F24513B5F8315EB163FBC328D9CAEE1DF00AF8D2AA3D4326`.
  - Signer SHA-256: `68:90:D4:8A:B8:F1:B2:60:83:92:FA:D0:F9:DF:FA:D9:D7:7F:12:57:55:4B:17:E2:A8:66:A7:D2:E7:D1:16:DA`.
  - `apksigner verify --verbose --print-certs`: Verified, APK Signature Scheme v2 true.
  - First Honor installation returned `INSTALL_FAILED_ABORTED: User rejected permissions` while locked. After the user's explicit retry request, `adb install -r` succeeded with existing data preserved. The original failed conversation regenerated a complete, relevant answer; Settings confirmed Vulkan / Adreno 830 / batch 1 / microbatch 1 and the compatibility note. Final PID `2580` had no crash entries, and the app was left showing the user's conversation. Screenshots are in `docs/images/qa-honor-vulkan-*.png`.
  - Existing upstream flutter_tts Kotlin compatibility notice remains; release build succeeds. Prior blocked duplicate APK-output cleanup was not retried or bypassed.
- **Limit**: Adreno compatibility processes prompts one token at a time and may be slower for long questions. This validates the supplied Qwen models and reported device failure, not every model or language-model answer.

---

## Session: 2026-09-06 (Fresh Pixel 6 Feature Reviews and Experimental Mali OpenCL)
- **Focus**: Completed independent UX/correctness reviews for Home/Dictionary, Listening, Chat/Study, Settings and OpenCL, followed by a fresh review of the resulting interfaces. Decisions, live evidence and deliberate limits: `docs/qa-pixel6-ux-2026-09-06.md`; native scope and reproduction: `docs/native-opencl-pixel.md`.
- **Changes**:
  - Home now opens explicit empty Dictionary/AI Translation flows, offers usable full-width tools, avoids fake badges/selected pills and covering FABs, and confirms lesson deletion. Dictionary retains custom regeneration intent, original saved sentence/Unicode text and current saved state across Study edits.
  - Study opens complete saved meanings offline, exposes confirmed removal and displays the actual scheduler's review intervals. Constrained mobile/text-scale layouts remain usable.
  - Listening Previous selects the preceding cut, split navigation follows the selected left cut, and manual Add can recover missed speech in gaps. Hardened rapid Auto toggles, explanation ownership and shared native Whisper cancellation/request ownership.
  - Chat displays actual sentence context, selectable Markdown and labeled speech controls. Voice capture/transcription respects draft, tab, route and app lifecycle ownership; first permission now records immediately. English pronunciation resets the shared TTS language after Chinese chat speech.
  - SAF downloads share an event subscription with per-request routing and retain ownership until native stream closure/terminal acknowledgement. Prevented duplicate downloads and folder changes during finalization; fixed identity/deletion error handling. Settings applies CPU thread changes once at drag end, displays errors/cancellation clearly, and wraps full model names with separate badges.
  - Added an optional, restricted Mali-G78 OpenCL backend without modifying vendor submodules or packaging vendor drivers. Q4_K/Q6_K matmul runs on GPU; unsupported operations and KV remain on CPU. Auto continues to choose Vulkan/CPU. Settings explicitly labels the mixed OpenCL path experimental and potentially slower.
- **Physical and Native Verification**:
  - Pixel 6 `25311FDF6004PR`: real offline word lookup, Chinese sentence translation, original-text vocabulary saving/detail/removal and saved-star synchronization; fresh audio import, manual transcription, Auto OFF cache gating, locked/editable bounds, gap-add/split, same-file persistence, Redo and Reset.
  - Signed app: first microphone grant immediately entered Recording, cancellation returned idle; real OpenCL load and Chinese Hello explanation succeeded; chat cancellation, regeneration, Markdown/history/deletion passed. Per-cut Whisper returned Hello within the roughly four-second capture interval. Replay/Repeat completed over six 1142-2240 ms cycles and stopped on Pause.
  - Concurrent Whisper Base and SmolLM2 downloads both completed; cancelling a subsequent active download returned GET and removed its partial file. Removed only QA downloads, lesson/source, vocabulary entry and conversations. Original three lessons, three vocabulary entries and Qwen/Whisper models were retained; Auto restored.
  - Native: 12 Mali kernel comparisons passed (maximum scaled error < 4.4e-5); missing driver/API concurrent loader tests passed. Exact Gradle ARM64 library passed CPU, Vulkan and OpenCL arithmetic/Chinese/grammar smoke. Long-prompt, cancellation/recovery and unload/reload fixtures passed. ARM64 and x86_64 native release builds succeeded.
  - Final layout-only signed upgrade succeeded with `adb install -r`; full model names and loaded inventory confirmed, final PID `11420`, no new crash entries, app left on Home. Earlier isolated native experiment crash entries are documented separately and were not app crashes.
- **Static Analysis**: `flutter analyze` -> `No issues found!` (zero errors/warnings).
- **Tests**: `flutter test --concurrency=1` -> `253 passed`, zero failed (64 seconds).
- **Signed Release**:
  - `flutter build apk --release` succeeded using `app/android/key.properties` (58.7 seconds).
  - Fixed path: `release/app-release.apk` (94,947,605 bytes).
  - APK SHA-256: `84FA762ACF4B45A0E7FD95741B16DD5644351FA0CB5899ED455A10C0CCF2FB28`.
  - Signer SHA-256: `68:90:D4:8A:B8:F1:B2:60:83:92:FA:D0:F9:DF:FA:D9:D7:7F:12:57:55:4B:17:E2:A8:66:A7:D2:E7:D1:16:DA`.
  - `apksigner verify --verbose --print-certs`: Verified, APK Signature Scheme v2 true.
  - Existing upstream flutter_tts Kotlin compatibility notice remains; current release succeeds. Prior policy-blocked duplicate APK-output cleanup was not retried or bypassed.
- **Limits/Review Decisions**: Restricted OpenCL is validated on Mali-G78 and the supplied model, not all GPUs. Generic OpenCL and revision-aware multi-step segment undo were deferred due to broader implementation/validation scope. Qwen 0.5B still gave an inaccurate say/tell explanation despite numerically correct execution; backend success is not a claim of semantic accuracy. Microphone permission/capture/cancel was tested without supplied speech, so conversational recognition accuracy is not claimed.

---

## Session: 2026-09-07 (Quiet Waveform Visibility and 20-Second View)
- **Focus**: Addressed the user's quiet/missing-looking waveform, density, window length, color and non-editing boundary visibility requests. Evidence: `docs/qa-waveform-2026-09-07.md`.
- **Changes**:
  - Replaced the blue/pale-gray amplitude threshold and flat minimum display with neutral gray 1.25 dp bars and a fixed square-root height scale. Quiet signal becomes visible without altering raw PCM peaks or VAD.
  - Expanded the view to 20 seconds and 160 target bars, using fixed 125 ms timeline buckets that retain every intersecting source interval. Simplified heading to Local Window. Gray bars are painted above segment shading to avoid tinting.
  - Hidden boundary lines and touch targets unless Edit is active. Partitioned short-cut touch targets at their midpoint so both ends remain independently draggable.
- **Investigation/Device Check**:
  - Independent full TED decode review found no speech passage zeroed by channel averaging; many real quiet peaks were flattened by the old display scale. Extraction, cache format and automatic segmentation were therefore retained.
  - Pixel 6 `25311FDF6004PR`: Flutter hot reload verified gray/dense waveforms, 20-second timestamps and Edit-dependent boundaries. Final signed upgrade succeeded, existing lessons/models retained, final PID `20503`, no new crash entries; app left on Listening with Edit off.
- **Static Analysis**: `flutter analyze` -> `No issues found!` (zero errors/warnings).
- **Tests**: `flutter test --concurrency=1` -> `256 passed`, zero failed (66 seconds). Coverage includes stable scrolling, retained quiet peaks, uniform gray thin strokes, hidden handles, shade alignment and separate endpoint dragging for a 400 ms cut.
- **Signed Release**:
  - `flutter build apk --release` succeeded using `app/android/key.properties` (60.3 seconds); temporary debug signing changes removed.
  - Fixed path: `release/app-release.apk` (94,947,605 bytes).
  - APK SHA-256: `C5D6D9987082661A23AB26BEAF81D017A7B6CE6E63558FC564D280D45A4C83CD`.
  - Signer SHA-256: `68:90:D4:8A:B8:F1:B2:60:83:92:FA:D0:F9:DF:FA:D9:D7:7F:12:57:55:4B:17:E2:A8:66:A7:D2:E7:D1:16:DA`.
  - `apksigner verify --verbose --print-certs`: Verified, APK Signature Scheme v2 true.
  - Existing upstream flutter_tts future Kotlin compatibility notice remains; current release succeeds. Prior policy-blocked duplicate APK-output cleanup was not retried or bypassed.
