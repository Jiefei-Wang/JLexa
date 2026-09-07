# CPU inference regression on Honor PTP-AN00

## Diagnosis (2026-09-06)

A fresh Ask AI conversation on the Honor reproduced unrelated fragments and repeated citations for the built-in `say` / `tell` question. The selected model was Qwen2.5 1.5B Instruct Q4_K_M, and Settings reported CPU.

The model file `/sdcard/Models/llm/qwen2.5-1.5b-instruct-q4_k_m.gguf` was 1,117,320,736 bytes with SHA-256 `6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e`, matching the earlier verified download. Its GGUF metadata identifies Qwen2 and contains the chat template. The issue was reproduced in a standalone harness linked to the exact release native library, outside Flutter, chat history, and JNI text rendering.

The bridge set zero GPU weight layers for CPU mode but left `llama_model_params.devices` null. In the bundled llama.cpp API, null means use all available devices. The context also retained `op_offload=true` and `offload_kqv=true`. Consequently, the supposedly CPU-only model performed prompt operations on the Honor's Adreno 830 Vulkan backend. Native diagnostics showed two scheduler backends, a 482.32 MiB Vulkan compute buffer, and 396 graph splits for prompt processing.

The fix supplies an explicit empty GPU device list for CPU mode and disables context operation/KQV offloading whenever no GPU is selected. Accelerated selections retain their chosen device and offloading. The corrected run uses one CPU scheduler backend, a 302.75 MiB CPU compute buffer, and one graph split.

## Controlled comparison

Both runs used the same model file, descriptor loader (`/proc/self/fd/...`), native llama runtime, prompt, seed 1234, temperature 0, context 2048, batch/microbatch 512, and four threads. Each request cleared inference memory.

| Prompt | Before | After |
| --- | --- | --- |
| What is 2 plus 2? Reply with only the number. | Unrelated Chinese text about birthdays and percentages | `4` |
| Translate into Chinese: Good morning. | Unrelated English percentages and time listings | `早上好。` |
| Explain the difference between say and tell in two sentences. | Repetitive unrelated text about “the other 90%” | A relevant explanation of expressing something versus conveying information |

The first two checks are assertions in `native/tests/llama_cpu_smoke.cpp`; the third prints its answer for human review. This is a focused regression fixture using Qwen2.5 Instruct, not a general model-quality benchmark. CPU isolation fixes this observed corrupt inference path; it does not establish correctness of Adreno Vulkan kernels or every answer a small language model can produce. No model file, user conversation, generation prompt, or sampling setting was changed to obtain the fix.

The smoke test also passed when linked only to the final release `libjlexa_native.so`, with no separately compiled bridge override. That library belongs to signed APK SHA-256 `B0466185951A0A124C41D9A9FE27D432498B7799C06CA3B40AB6514FF61CF4A5`; all three answers matched the corrected controlled run.

After the signed upgrade, the Honor app itself generated `早上好。` for a fresh chat asking to translate “Good morning.”. Its built-in `say` / `tell` example produced relevant prose, although it still overstated `tell` as primarily giving instructions. This remaining language-model accuracy limitation is distinct from the previously reproduced unrelated output. Process PID 13889 remained stable and its crash buffer was empty. [Final chat screenshot](images/qa-honor-ai-fixed.png).

The same final app also verified the model-inventory fix: Settings displayed **Whisper Tiny (English), 74.1 MB, LOADED**, with **Saved model outside the selected folder**, while the selected shared folder's `whisper/` directory remained empty. Qwen2.5 1.5B also displayed LOADED. This confirms the older model remained usable and is now included in the visible inventory. [Final model screenshot](images/qa-honor-models-fixed.png).

## Reproduce against the built release library

Build the signed release first. From the repository root in PowerShell (adjust the installed NDK version and device serial if needed):

```powershell
$serial = 'adb-AJTLVB4B05002604-ROpSXf._adb-tls-connect._tcp'
$ndkBin = "$env:LOCALAPPDATA/Android/Sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/windows-x86_64"
$nativeLibs = 'app/build/app/intermediates/stripped_native_libs/release/stripReleaseDebugSymbols/out/lib/arm64-v8a'
New-Item -ItemType Directory -Force artifacts/cpu-regression | Out-Null
& "$ndkBin/bin/aarch64-linux-android28-clang++.cmd" -std=c++17 '-Inative/bindings' native/tests/llama_cpu_smoke.cpp "$nativeLibs/libjlexa_native.so" -o artifacts/cpu-regression/llama_cpu_smoke
adb -s $serial push artifacts/cpu-regression/llama_cpu_smoke /data/local/tmp/jlexa_llama_cpu_smoke
adb -s $serial push "$nativeLibs/libjlexa_native.so" /data/local/tmp/libjlexa_native.so
adb -s $serial push "$nativeLibs/libomp.so" /data/local/tmp/libomp.so
adb -s $serial push "$ndkBin/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" /data/local/tmp/libc++_shared.so
adb -s $serial shell chmod 755 /data/local/tmp/jlexa_llama_cpu_smoke
adb -s $serial shell 'LD_LIBRARY_PATH=/data/local/tmp /data/local/tmp/jlexa_llama_cpu_smoke /sdcard/Models/llm/qwen2.5-1.5b-instruct-q4_k_m.gguf' *> artifacts/cpu-regression/result.txt
if ($LASTEXITCODE -ne 0) { throw 'CPU inference regression failed' }
```

This runs a small diagnostic executable; it does not install an APK or modify application/model data. A successful run ends with `CPU inference smoke test: PASS`. Native output should report a CPU compute buffer and a single graph split; Vulkan device enumeration alone is not evidence of Vulkan computation.
