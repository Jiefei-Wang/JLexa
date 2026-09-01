# JLexa

JLexa is an offline-first, private English learning mobile app combining:

- **Offline English Dictionary & Stardict Lookup**
- **Looping Audio Lesson Repeater & Real-Time Waveform Alignment**
- **On-Device Speech-to-Text (Whisper.cpp)**
- **On-Device Local AI Explanations & Contextual Q&A (Llama.cpp)**
- **Vocabulary Builder with Spaced Repetition (SRS)**

---

## Local AI Model Management

JLexa provides a curated on-device AI experience with no cloud dependencies or API keys required.

### 1. In-App Model Catalog & Direct Downloading
Users can browse, download, activate, and delete curated Hugging Face models directly from the **Settings & Local Models** screen:

- **Language Models (LLM)**:
  - `Qwen2.5 0.5B Instruct` (468 MB) — Ultra-lightweight & rapid response.
  - `Qwen2.5 1.5B Instruct` (1.04 GB) — **[Recommended]** Excellent English explanations & grammar advice.
  - `Qwen2.5 3B Instruct` (1.96 GB) — Deep reasoning & nuanced linguistic Q&A.
  - `SmolLM2 360M Instruct` (368 MB) — Minimal memory footprint.
- **Speech Recognition Models (Whisper)**:
  - `Whisper Tiny (English)` (74 MB) — Instant on-device transcription.
  - `Whisper Base (English)` (141 MB) — **[Recommended]** High accuracy English audio transcription.
  - `Whisper Small (English)` (465 MB) — Maximum transcript precision.

### 2. Custom Model Import (Alternative)
Users who have custom GGUF or Whisper `.bin` / `.ggml` files can import them into JLexa using the **Import Local GGUF** and **Import Local Whisper Model** buttons. Files are validated and safely imported into managed app storage without triggering Android MIME-type filter errors.

### 3. Managed Storage Architecture
- **LLM Models**: `<app_support>/models/llm/<filename>.gguf`
- **Whisper Models**: `<app_support>/models/whisper/<filename>.bin`
- **Resilient Downloads**: Downloads stream to temporary `.part` files with pause/cancel support and atomic rename upon completion. Stale partial downloads are cleaned up automatically on app startup.

---

## Automated Windows + Android Emulator Testing

JLexa includes a full-stack automation runner in PowerShell (`scripts/test_android.ps1`) enabling CI and coding agents to test builds on Windows with an Android Emulator without manual intervention:

```powershell
# Run the complete automated test pipeline (headless emulator)
powershell -ExecutionPolicy Bypass -File .\scripts\test_android.ps1 -Headless

# Run against an already running emulator or connected device
powershell -ExecutionPolicy Bypass -File .\scripts\test_android.ps1 -SkipEmulator
```

### Automation Pipeline:
1. **Environment Verification**: Locates Android SDK, Java Studio JBR, `adb`, `emulator`, and CLI tools.
2. **Device Discovery & Provisioning**: Automatically starts/provisions the Android emulator (`JLexa_Test_AVD`) and polls `adb shell getprop sys.boot_completed` until online.
3. **Dependency Check**: Runs `flutter pub get`.
4. **Static Analysis**: Runs `flutter analyze`.
5. **Unit & Widget Testing**: Runs 110+ unit & widget test suites (`flutter test --concurrency=1`).
6. **APK Compilation**: Compiles the debug APK (`flutter build apk --debug`).
7. **On-Device Integration Tests**: Executes end-to-end integration tests on the emulator (`flutter test integration_test/model_settings_test.dart -d <device>`).
8. **Failure Diagnostics**: Automatically dumps full logcat and captures device screenshots into `test_artifacts/<timestamp>_failure/` upon any failure.

---

## Repository Structure

```
JLexa/
├── app/
│   ├── android/                  # Android Gradle build & native bridge integration
│   ├── integration_test/         # On-device end-to-end integration tests
│   ├── lib/
│   │   ├── core/
│   │   │   ├── ai/               # ModelCatalog, ModelStorage, ModelDownloader, ModelManager, AiService
│   │   │   ├── audio/            # AudioService, WaveformService, LessonRepository
│   │   │   ├── database/         # AppDatabase SQLite schema & migrations
│   │   │   ├── dictionary/       # Stardict & offline dictionary lookup
│   │   │   └── vocabulary/       # SRS scheduler & vocabulary repository
│   │   ├── features/             # Home, Repeater, Dictionary, Vocabulary, AI Chat, Settings
│   │   └── main.dart
│   └── test/                     # Comprehensive unit & widget test suites
├── native/                       # Native C++ Llama and Whisper source dependencies
└── scripts/
    └── test_android.ps1          # Automated Windows emulator & testing runner
```
