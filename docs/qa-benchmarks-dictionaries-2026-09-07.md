# Whisper benchmarking, Home cleanup and dictionary management

Whisper Benchmark is available beside Import under **Whisper Backend**.
Its table has selected backends as rows and Short (s) / Long (s) columns.
All installed backends are selected initially. Test runs the currently loaded
Whisper model on fixed 3.575-second and 20.205-second English samples, using four
threads. Results measure the synchronous native recognition call, excluding
asset preparation, backend switching and model loading. Test/Stop, current
progress and recognized text remain available, with model-specific history.
The original model/backend is restored after completion, cancellation, and
recoverable errors; the speech engine remains busy until restoration finishes.
These are single-run elapsed times, not warmed medians or accuracy scores.

LLM Benchmark retains backend selection, saved prefill/decode results, streaming
translation and Test/Stop while removing the explanatory introduction. Both
tables support narrow screens and enlarged fonts.

Home no longer repeats Dictionary / Listening / Ask AI shortcuts above the
bottom navigation. Quick Tools contains **Dictionary Manager** and **Settings**.
Search, recent items, study and listening flows remain available.

Dictionary Manager enables/disables built-ins and imports/removes dictionaries.
Imports are copied privately, parsed outside the UI isolate, and indexed
transactionally. Supported formats and exact limitations are documented in
[dictionary-import.md](dictionary-import.md). Tests cover MDX 1.2/2.0, encrypted
key metadata, zlib checksums and expansion limits; StarDict 32/64-bit offsets,
gzip/dictzip, synonyms and malformed metadata; text formats, safe HTML-to-text,
failed-import rollback, enable/disable/delete, and persisted catalog state.

## Build and installation

- `flutter analyze --no-pub`: no issues (zero errors/warnings).
- `flutter test --concurrency=1`: 366 passed, zero failed. Includes a regression
  proving dictionary management refreshes offline data without restarting or
  cancelling an active AI answer.
- `flutter build apk --release`: succeeded with `app/android/key.properties`.
- `apksigner verify --verbose --print-certs`: verified, APK v2 signature true.
- Fixed artifact: `release/app-release.apk`, 114,228,531 bytes.
- APK SHA-256: `4FB2F6509F62F44C1E1D1B83F7BD8A966E4B13B3FB2DEE2D4DD587C7DB2BCAFF`.
- Signer SHA-256: `6890d48ab8f1b2608392fad0f9dffad9d77f1257554b17e2a866a7d2e7d116da`.
- Signed in-place installation succeeded on Pixel 6 (`25311FDF6004PR`) and
  Honor PTP-AN00 (`AJTLVB4B05002604`, wireless ADB). Installed `base.apk` SHA-256
  on each device matches the fixed release artifact. Existing app data preserved.
- Existing upstream flutter_tts future Kotlin compatibility warning remains;
  current release succeeds. Previously blocked duplicate APK removal was not
  retried or bypassed; generated build copies remain outside the fixed release.

## Honor native fixture validation

The same PCM samples bundled in the app were tested through the native plugin
harness on Honor with the existing Tiny.en model and Snapdragon Whisper CPU
plugin while the device screen was locked. PCM was rewrapped with a standard
44-byte WAV header for this harness without changing sample data; the app reads
the bundled 46-byte header directly.

| Sample | Audio length | First inference | Median of 3 subsequent runs |
| --- | ---: | ---: | ---: |
| Short | 3.575 s | 647.918 ms | 614.802 ms |
| Long | 20.205 s | 2564.924 ms | 834.706 ms |

Both transcripts matched the original fixture text. Load/transcribe/stop/reset/
unload/destroy checks passed. These harness measurements are distinct from the
app's one-pass short-then-long table. Logs:
`test_artifacts/whisper-app-honor-short.log` and
`test_artifacts/whisper-app-honor-long.log`.

## Honor app UI

After the user unlocked the phone, Whisper Tiny (English) ran through both
selected backends in the actual Benchmark screen:

| Backend | Short | Long |
| --- | ---: | ---: |
| Built-in CPU | 0.60 s | 0.77 s |
| JLexa Whisper Snapdragon CPU | 0.44 s | 0.65 s |

The first complete run measured 0.63/0.80 s and 0.47/0.66 s respectively.
Deselection limited a subsequent run to CPU; Stop marked that row cancelled and
preserved the unselected plugin's last measurements. The original Snapdragon
Whisper backend was Loaded after leaving the screen. Following another complete
run, force-stop/relaunch retained all four table values above and restored the
selected model/plugin. Both checkboxes were selected on reopening. App PID 16699
remained stable with an empty PID-filtered crash buffer; unrelated historical
system/WeChat/harness crash records were not attributed to JLexa.

Screenshots: [table](images/whisper-benchmark-honor-2026-09-07.png),
[stopped](images/whisper-benchmark-honor-stopped-2026-09-07.png),
[restored results](images/whisper-benchmark-honor-restart-2026-09-07.png).

## Pixel dictionary UI

- Home's duplicate Dictionary/Listening/Ask AI actions are gone; Quick Tools
  opens Dictionary Manager and Settings using the requested English names.
- Actual Android file-picker imports succeeded for Encrypted=2 MDX, StarDict
  ZIP with gzip index/dictzip data, and UTF-8 TSV. The new words `jlexacrypt`,
  `jlexastar`, and `jlexatext` returned their self-authored fixture definitions.
- Unsupported MDX 3 showed a clear error and left the five-item catalog intact
  (two built-ins and three successful imports).
- Force-stop/relaunch preserved the imports and their definitions. Disabling
  StarDict survived another restart and removed its word from lookup; enabling
  it again immediately restored the existing query's result.
- Delete/Cancel preserved the dictionary; confirmed Delete removed it and its
  lookup result. All three QA dictionaries and the four staged source files
  were removed afterwards. Existing user models, lessons, and history remained;
  the three QA query-history entries were not removed because the UI offers
  only clearing the entire history.
- ADB-pushed files were visible through Pixel 6 → Download in the system file
  picker. The separate Downloads provider had not indexed the newly staged
  files, so its initially empty listing was not treated as an import failure.

Screenshots: [Home](images/home-tools-2026-09-07.png),
[Quick Tools](images/home-quick-tools-2026-09-07.png),
[catalog](images/dictionary-manager-pixel-2026-09-07.png),
[MDX lookup](images/dictionary-mdx-lookup-pixel-2026-09-07.png),
[invalid format](images/dictionary-import-error-pixel-2026-09-07.png).

## Pixel speech descriptor regression and final upgrade

The first Pixel Whisper Benchmark exposed a retained SAF descriptor at EOF.
The bundled adapter uses `dup()`, so the duplicate shares the source offset;
reloading the same model after initial use failed. `JLexaSpeechHost::loadModel`
now rewinds `/proc/self/fd/<fd>` before each attempt, including fallback and
restoration. This requires a valid seekable model descriptor and does not expose
engine internals through the host ABI.

The new `native/tests/speech_host_fd_test.cpp` runs against a fixture which
consumes the shared descriptor. The previous host deterministically failed;
the fixed host passed repeated load/unload, failed external load followed by
built-in fallback, original plugin restoration, and invalid/non-seekable FD
rejection. Evidence: `test_artifacts/speech-host-fd-before.log` and
`test_artifacts/speech-host-fd-after.log`.

On the final signed APK, Pixel's actual Whisper Benchmark with SAF Tiny.en
completed at 1.32 s short / 1.71 s long. Test followed by Stop produced a cancelled
row, and another Test completed successfully. Screenshot:
[Pixel Whisper](images/whisper-benchmark-pixel-2026-09-07.png).
The simplified LLM screen also completed CPU generation with Qwen2.5 0.5B,
showing 74.3 prefill tok/s and 34.9 decode tok/s. Existing unselected Vulkan and
OpenCL history stayed visible; those GPU rows were not rerun in this UI pass.
[LLM table](images/llm-benchmark-pixel-2026-09-07.png).

Honor retained the exact previous table and selected Snapdragon plugin after
the final signed upgrade. A further run on the final APK measured CPU 1.13/0.79 s
and Snapdragon 0.44/0.67 s. All text was recognized, and Settings restored
Snapdragon Whisper to Loaded. PID 19543 had an empty filtered crash buffer.
[Final Honor table](images/whisper-benchmark-honor-final-2026-09-07.png).
Single-run timings vary with warm-up, power and thermal state.

Pixel's post-cancellation complete run measured 1.34/1.73 s; force-stop/relaunch
restored those exact values with Whisper Tiny (English) loaded. The final Pixel
PID was 19416 with an empty PID-filtered crash buffer. Final installed APK
hashes on both phones match the release SHA above.
[Pixel restored table](images/whisper-benchmark-pixel-restart-2026-09-07.png).
