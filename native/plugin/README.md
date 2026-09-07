# JLexa LLM plugin ABI v1

Settings → **Backend Plugins** → **Import .so** accepts an Android ARM64 shared
library built against [jlexa_plugin.h](jlexa_plugin.h). An ordinary upstream
`libllama.so` does **not** implement this interface and is rejected.

The APK always contains `libjlexa_llama.so` as the default. The UI/JNI host
loads both that library and imported libraries through the same C interface.
Only `llama_plugin.cpp` and the existing engine adapter depend on llama.cpp;
the host is not linked to llama.cpp and does not include its headers. Whisper
continues using its existing bridge. Engine symbols are hidden to avoid ggml
symbol collisions between independently built engines.

## Implementing a plugin

Export one unmangled symbol with default visibility:

```c
const jlexa_plugin_api *jlexa_plugin_get_api(void);
```

It returns a process-lifetime table whose `abi_version` is `JLEXA_PLUGIN_ABI`
and whose `struct_size` is at least `sizeof(jlexa_plugin_api)`. Every function
pointer and metadata string in v1 is required. Version changes that alter
semantics or layout require a new ABI version. Plugin version is a separate,
human-readable string.

The table supplies metadata, create/destroy, model load/unload, generation,
cancellation/reset, model status, device discovery and effective runtime
information. The last three retain the existing Settings behavior.

Contract:

- All strings are NUL-terminated UTF-8. Metadata strings/table remain valid
  until `dlclose`. Input strings/arrays are borrowed only until a call returns.
- All integers have the widths in the header; compile with the normal Android
  ARM64 C layout, without custom packing. No STL types, exceptions, allocators
  or engine-owned buffers cross the ABI. The plugin frees its own backend.
- `load_model` returns 0 on success and -1 on failure. `generate` is synchronous:
  0 means success, 1 cancelled, -1 failure. Write a terminated error message
  within the supplied capacity on failure. Do not throw across this C API.
- Generation token callbacks run on the calling thread and must finish before
  `generate` returns. The host sends the final Flutter completion event.
- `stop` is thread-safe, promptly interrupts generation, and must not clear
  cancellation at the start of generation. `reset_cancellation` is called by
  the host before accepting a new request. Other operations are serialized.
- Model paths may be `/proc/self/fd/N`. Open/read them synchronously and retain
  any required model file/mapping until unload. Do not assume a `.gguf` suffix.
  The app holds its SAF descriptor for the loaded model's lifetime.
- Chat roles/content are provided separately; the engine applies its own model
  chat template. Runtime settings are requests; report the effective settings
  and available devices accurately. Unsupported settings can fail clearly.
- Return device counts no larger than the supplied capacity. Terminate strings
  in output structs. Use the existing lowercase `cpu`, `vulkan`, `opencl`
  device identifiers to retain the existing runtime selector.

Build for `aarch64-linux-android28` or a compatible lower minimum API. Prefer
static engine/C++ dependencies in the single `.so`; retain only Android system
dependencies or libraries supplied by the app. No adjacent dependency files
are imported. Missing dependencies produce a normal loader error. Keep all
symbols except `jlexa_plugin_get_api` hidden; `exports.map` is an example linker
version script. Use 16 KB ELF segment alignment for modern Android devices.

`llama_plugin.cpp` is the real implementation used by the built-in backend.
After `flutter build apk --release` in `app/`, the APK member
`lib/arm64-v8a/libjlexa_llama.so` can also be extracted and imported as a real
external plugin. `native/tests/plugin_fixture.c` is a minimal executable ABI
example, with deterministic test text rather than language-model inference.
Build all fixtures with `native/tests/build_plugin_fixtures.ps1`.

## Import, recovery and scope

The file picker supplies a document stream. JLexa copies it under
`Context.noBackupFilesDir/backend_plugins/<uuid>.so`, marks it read-only through
the open write descriptor, flushes/closes it, and checks ELF64/little-endian/
`EM_AARCH64`/`ET_DYN`. The native loader rechecks architecture and write bits
before `dlopen(RTLD_NOW | RTLD_LOCAL)` and `dlsym`.

A non-exported `:plugin_probe` service first exercises library constructors,
ABI inspection, backend creation and destruction. A crash or 18-second probe
timeout is rejected while the main app stays alive. This is crash containment,
not a security sandbox: imported native code must be trusted by the user.

The selected private path and failure details are stored in the app's
`backend_plugins` SharedPreferences and restored before model startup. Import
or ordinary model-load failures select the bundled backend and reload the
previous model. Cancelling the picker restores the same model/backend.

A synchronous on-disk initialization marker covers the subsequent in-process
activation and model load. If these terminate the main process, the **next
launch** selects the built-in backend instead of repeating a startup crash.
Arbitrary native crashes during later generation cannot be recovered in the
same process. Full out-of-process inference is intentionally outside this
small loader. Probe success cannot guarantee every future plugin operation.

Only one imported backend is retained. Selecting built-in removes unused
private plugin copies; user source files and model files are preserved. There
is no catalog, downloader, updater, dependency resolver or network operation.
