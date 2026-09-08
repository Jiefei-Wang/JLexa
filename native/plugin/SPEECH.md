# JLexa speech plugin ABI v1

Settings → **Whisper Backend** → **Import** adds an Android ARM64 speech
backend. Select its row to use it; the trash icon removes it. Import does not
change the current selection. Deleting the active import restores built-in
Whisper CPU and reloads the selected model. LLM and speech catalogs, selections,
initialization recovery markers and disposable probe processes are independent.

The host loads the bundled `libjlexa_whisper.so` and external speech libraries
through [jlexa_speech_plugin.h](jlexa_speech_plugin.h). It has no dependency on
whisper.cpp or llama.cpp. The existing Whisper engine adapter retains its model
loading, English transcription, token timestamps, confidence and cancellation
behavior. No audio decoding/segmentation or model weights are changed.

## Contract

Export only `jlexa_speech_plugin_get_api` with C linkage/default visibility. It
returns a process-lifetime table with `abi_version = JLEXA_SPEECH_ABI` and
`struct_size >= sizeof(jlexa_speech_api)`. All metadata strings and function
pointers in v1 are required. LLM's `jlexa_plugin_get_api` is a different contract
and is not accepted by the speech selector.

- Input is mono 16 kHz float32 PCM; model paths may be `/proc/self/fd/N` from SAF.
- Strings are UTF-8. Input and callback memory is borrowed only during the
  corresponding call; the host copies segments/tokens before callbacks return.
- Segment/token timestamps are milliseconds relative to the input PCM range.
  The existing Android bridge applies lesson offsets. Confidence is a
  probability, or a negative value when unknown. Do not return control tokens.
- `load_model`: 0 success, -1 error. `transcribe`: 0 success, 1 stopped, -1 error.
  Write a terminated error string within the caller's supplied buffer capacity.
- Transcription is synchronous; callbacks run on its calling thread and stop
  before return. `stop` is thread-safe and leaves cancellation latched until
  `reset_cancellation`. Other calls are serialized. No C++ exceptions cross ABI.
- The plugin owns its allocations; `destroy` must release its model and state.
  Hide internal symbols and statically link non-system dependencies to avoid
  collisions with other loaded engines. Use 16 KB ELF segment alignment.

`whisper_plugin.cpp` is the reference implementation. Compile it with the
existing `native/bindings/jlexa_whisper_bridge.cpp` and pinned whisper.cpp.
The public header is also usable from C; `native/tests/speech_plugin_fixture.c`
provides test fixtures (`API_VERSION=99`, `CRASH_INIT=1`, `FAIL_MODEL=1`).

## Loading and recovery

The shared importer copies into `no_backup/speech_backend_plugins/<uuid>.so`,
marks it read-only, validates ELF ARM64 and probes its speech API/create/destroy
in non-exported `:speech_plugin_probe`. Model-load failure falls back to bundled
Whisper and the selection transaction attempts to restore the previous backend.
A persisted initialization marker prevents repeated startup/model-load crashes
on the next launch. Transcription-time native crashes still require restart;
this is not out-of-process inference or a sandbox for untrusted native code.

Speech selection changes are rejected while transcription/model changes are
active. Imports and deletion of inactive entries leave loaded models intact.
App restart restores the speech selection before loading its saved model.

## Optimized CPU build and measurement

`native/snapdragon/build.ps1 -Whisper` builds
`release/jlexa-whisper-snapdragon-plugin.so`; add `-Baseline` to build the
generic ARMv8 control. The optimized variant checks FP16, dotprod and i8mm
capabilities before engine creation; unsupported CPUs are rejected. Only CPU
kernels use stronger instructions. The ABI adapter stays on baseline ARM64.

Build `native/tests/speech_plugin_benchmark.cpp` with the Android ARM64 NDK
compiler, `-std=c++17 -O2 -static-libstdc++ -Inative/plugin -ldl`. On the phone:

```text
speech_plugin_benchmark PLUGIN_PATH MODEL_PATH PCM16_MONO_16000HZ_WAV
```

The harness measures one cold and three warm transcriptions with four threads,
excluding model loading and audio file decoding. It prints elapsed time,
audio duration/processing time, and full text, then checks pre-cancel,
in-progress stop, reset, successful reuse, unload and destruction. Compare
warm medians with the same model/audio and retain cold measurements separately.
These speech measurements are independent of the Settings LLM token benchmark.
Device results and limitations: [QA report](../../docs/qa-whisper-plugins-2026-09-07.md).
