# Honor Vulkan generation failure

## Reproduction

On 2026-09-06, Honor PTP-AN00 showed the following error after explicitly selecting Vulkan and asking the built-in `say` / `tell` question:

> Native inference failed: vk::Device::createComputePipeline: ErrorUnknown

The installed signed release was `B0466185951A0A124C41D9A9FE27D432498B7799C06CA3B40AB6514FF61CF4A5`. The process remained alive. Its selected Qwen2.5 1.5B Instruct Q4_K_M file was the same 1,117,320,736-byte file used in the [CPU regression](native-cpu-regression.md), with SHA-256 `6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e`.

A standalone Android harness reproduced the failure against the release native library. It failed while creating `mul_mat_vec_q4_k_f32_f32` on the Adreno 830. This is separate from the earlier CPU isolation bug: the user deliberately selected GPU execution in this case.

The app's CMake configuration adds Whisper before llama.cpp, so the shared GGML Vulkan target is compiled from `native/whisper.cpp/ggml`, pinned at `c4ac0012`. The corresponding Q4_K matvec shader in the pinned llama.cpp revision `3173a564` is identical. Merely changing the other submodule's shader would not change this application build.

## Controlled GPU diagnosis

The native probe used the same model file, seed 1234, temperature 0, and three short prompts for arithmetic, `say` / `tell`, and Chinese translation. Each request started with cleared inference memory.

| Variant | Observed result on Adreno 830 |
| --- | --- |
| Original release | Q4_K compute-pipeline creation failed |
| Disable F16 / Flash Attention; smaller normal batch; force MMVQ; disable fusion | Same failure |
| Shared-memory subgroup reduction; one-row tile; disable floating-point controls; disable robustness; 32-bit unpack | Same failure |
| Roll shader loops plus 32-bit unpack, batch 512 | Pipeline compiled, but output was unrelated repetitive text |
| Roll shader loops plus 32-bit unpack, batch/microbatch 8 | Multi-column Q4_K pipeline still failed to compile |
| Roll shader loops plus 32-bit unpack, batch/microbatch 1, Flash Attention Auto or Off | All three requests completed on Vulkan; arithmetic returned `4`, translation returned `早上好。`, and `say` / `tell` output was relevant |
| Remove the 32-bit unpack change from the successful variant | Compilation still succeeded, but unrelated output returned |

The successful run placed model layers on `Vulkan0` and used a Vulkan compute buffer (approximately 0.59 MiB), with two scheduler graph splits. These are actual GPU runs. All three changes are required by the controlled tests: loop controls, mathematically equivalent 32-bit unpack arithmetic, and the small batch. The small batch avoids both the failing multi-column kernel and the separate incorrect batched-prefill behavior observed on this device. The exact driver/compiler cause of the incorrect output has not been established. These fixtures verify the reported failure; they are not a general semantic-quality benchmark.

The compatibility path has a performance tradeoff: it processes the prompt one token at a time. Settings shows the effective batch and microbatch and explains that longer questions may take more time. Requested preferences remain saved for other compatible devices/backends.

## Failed pipeline retry

The original failed shader compile left `compile_pending=true` and never notified its waiters. A second generation skipped compilation and waited indefinitely for `compiled=true`. Successful compilation and terminal failure must both wake waiters; merely clearing `compile_pending` is insufficient for already-waiting requests.

The fix records the exception under the compile mutex, releases partially created Vulkan handles, clears pending, and notifies all waiters. Both the claim path and the waiting path rethrow a cached failure. A failure remains terminal for that pipeline on that device; it does not trigger an automatic CPU retry or claim that a GPU answer succeeded.

## Reproducible build

The repository owns two CMake overlays under `app/android/app/src/main/cpp/cmake/`. They generate a replacement Vulkan C++ source and Q4_K/Q6_K shader sources in the build directory. The C++ source is checked against a normalized hash of the pinned upstream file; the shader replacements check expected unpack calls and source structure. Updating GGML requires reviewing these guards. No private submodule commit or manual vendor edit is required.

The loop-control rewrite is restricted to Qualcomm Adreno 830 and Q4_K/Q6_K matvec shaders. The equivalent unpack arithmetic is compiled for both GPU types. The bridge limits effective batch/microbatch to 1 only for Vulkan on Adreno 830. CPU isolation remains intact. The native compatibility fixture checks device/kernel scoping, preservation of unrelated SPIR-V words and control bits, idempotence, and malformed input rejection.

`native/tests/llama_cpu_smoke.cpp` now accepts an optional `cpu` or `vulkan` argument. It verifies the active backend and prints effective batch sizes, performs three sequential generations, asserts arithmetic and Chinese translation, and prints the language explanation for review. The [CPU reproduction commands](native-cpu-regression.md#reproduce-against-the-built-release-library) also work with `vulkan` appended to the executable's arguments.

## Runtime settings recovery

Previously, runtime settings were saved before reloading the model, and reload exceptions were swallowed. A failed change could therefore leave the engine unloaded while Settings and persisted preferences claimed success.

Runtime changes now save only after a successful reload, serialize concurrent changes, reject changes during generation, and restore the previous model with its actual loaded runtime if the new configuration fails. Restoration failure is reported separately and clears stale active-backend details. Settings disables repeated backend/reset taps while applying the change.

Four regression tests cover successful rollback (including an explicit runtime override different from saved settings), rollback failure, concurrent switches, and an active generation. `flutter analyze` reports no issues; `flutter test --concurrency=1` passes all 191 tests.

## Device regression and signed release

The packaged native library (without diagnostic environment flags) passed the three-generation fixture on:

- Honor PTP-AN00, Qwen2.5 1.5B Q4_K_M, explicit Vulkan: Adreno 830, effective batch/microbatch 1, arithmetic `4`, translation `早上好。`, relevant `say` / `tell` answer.
- Honor PTP-AN00, the same model, CPU: batch/microbatch 512; arithmetic and translation assertions passed.
- Pixel 6, Qwen2.5 0.5B Q4_K_M, explicit Vulkan: Mali-G78, batch/microbatch 512; arithmetic and translation assertions passed. The Adreno batch limit did not apply.

A separate raw llama.cpp fixture deliberately bypassed the application's batch limit and requested batch 8 on Honor. It reproduced `createComputePipeline: ErrorUnknown` on both attempt 1 and attempt 2, returned promptly each time, and freed its context. This exercises the previously hanging retry path against a real driver failure.

- `flutter analyze`: zero issues.
- `flutter test --concurrency=1`: 191 passed, zero failed.
- `flutter build apk --release`: succeeded with the existing release signing configuration.
- `apksigner verify --verbose --print-certs`: verified, Signature Scheme v2 true.
- Fixed output: `release/app-release.apk`, 93,342,637 bytes.
- APK SHA-256: `0374BF4D86BEA820F24513B5F8315EB163FBC328D9CAEE1DF00AF8D2AA3D4326`.
- Signer SHA-256: `68:90:D4:8A:B8:F1:B2:60:83:92:FA:D0:F9:DF:FA:D9:D7:7F:12:57:55:4B:17:E2:A8:66:A7:D2:E7:D1:16:DA`.

The first Honor upgrade attempt returned `INSTALL_FAILED_ABORTED: User rejected permissions` while the phone was locked. After the user requested another attempt, `adb install -r` succeeded with existing data preserved (package update time 2026-09-06 22:16:15). No installer confirmation was bypassed.

In the upgraded app, the user's original failed conversation reopened with its saved question and error. Tapping **Regenerate answer** produced a complete, relevant `say` / `tell` explanation with no Vulkan error. Settings confirmed **VULKAN**, **Adreno (TM) 830**, batch/microbatch **1 / 1**, and the compatibility note. Process PID `2580` remained stable and had no crash-buffer entries. The app was left displaying the user's conversation. The answer still oversimplifies some word usage, which remains a small-model accuracy limitation rather than the previously unrelated/corrupted output.

- [Regenerated answer in the final app](images/qa-honor-vulkan-answer.png)
- [Actual Vulkan runtime in Settings](images/qa-honor-vulkan-runtime.png)
- [Additional native fixture commands](adreno-vulkan-regression.md)

The earlier policy rejection of duplicate build-output APK deletion remains respected; those build outputs were not removed.
