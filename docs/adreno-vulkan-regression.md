# Adreno 830 Vulkan inference regression

The Honor PTP-AN00 failure was reproduced with the installed Qwen2.5 1.5B Instruct Q4_K_M model and the release native library. Vulkan device enumeration and model loading succeeded, but generation failed while compiling `mul_mat_vec_q4_k_f32_f32` with `vk::Device::createComputePipeline: ErrorUnknown`. A second request then hung because the abandoned pipeline still had a pending compile flag.

The device reports Adreno (TM) 830, driver version 2150760490. Its advertised Int8, Float16, 8-bit storage, and 16-bit storage features are present. This was not a missing model or an unsupported-feature flag in Settings.

## Verified compatibility changes

- On Adreno 830 only, change Q4_K/Q6_K matrix/vector SPIR-V loop hints to retain loop bodies. This avoids the driver compiler failure for the scalar shader.
- In those shaders, unpack unsigned bytes with equivalent 32-bit shifts/masks. The original 8-bit conversion path produced incorrect inference even after the shader compiled. The replacement also passed the Pixel 6 Vulkan regression.
- Use an effective batch and microbatch of one on Adreno 830 Vulkan. Larger batches still failed compilation or produced incorrect results. Requested settings remain saved; active runtime information reports the actual values. Flash-attention preference remains unchanged.
- Cache pipeline compilation exceptions, release partially created Vulkan objects, clear pending claims, and wake waiting callers. Repeated failures terminate with an error instead of waiting indefinitely.

The application continues using Vulkan on the Honor. The workaround does not relabel CPU execution as Vulkan. Smaller batches can slow prompt preparation, especially for long chat history.

The vendor submodule remains at its pinned revision and clean. Root-owned CMake overlays generate replacement C++ and shader sources inside the build directory. Guarded replacements fail clearly if the pinned source changes. CPU isolation from the preceding fix remains in place.

## Device checks

The deterministic Qwen regression uses seed 1234, temperature zero, context 2048, and four threads. It asserts `4` for a two-plus-two question and `早上好` for a morning translation, and prints a third language-learning answer for review.

| Device / backend | Effective batch / microbatch | Result |
| --- | --- | --- |
| Honor Adreno 830 Vulkan, Qwen 1.5B | 1 / 1 | PASS; Vulkan compute buffer 0.5854 MiB |
| Honor CPU, Qwen 1.5B | 512 / 512 | PASS; CPU compute buffer 302.75 MiB |
| Pixel 6 Mali-G78 Vulkan, Qwen 0.5B | 512 / 512 | PASS; Vulkan compute buffer 298.5 MiB |

The final release native library was also tested on Honor. It reported `ACTIVE: vulkan / Adreno (TM) 830, batch=1, ubatch=1`, returned the correct arithmetic and translation, and completed all three sequential requests. APK SHA-256: `0374BF4D86BEA820F24513B5F8315EB163FBC328D9CAEE1DF00AF8D2AA3D4326`.

The raw failure regression deliberately bypasses the application's batch cap and requests the unsupported eight-column shader. Two consecutive calls returned the same compiler error and context teardown completed in a few seconds. Before the fix, the second call remained stuck. This test uses the actual Vulkan error, not a mocked exception.

These checks establish recovery and the tested GPU execution path, not universal semantic accuracy of a small language model.

## Reproduction

Build the signed APK, then use the NDK/shared-library setup in [the CPU regression instructions](native-cpu-regression.md). `native/tests/llama_cpu_smoke.cpp` now accepts an optional backend argument:

```powershell
adb -s $serial shell 'LD_LIBRARY_PATH=/data/local/tmp timeout 45 /data/local/tmp/jlexa_llama_cpu_smoke /sdcard/Models/llm/qwen2.5-1.5b-instruct-q4_k_m.gguf vulkan'
```

For the independent Adreno-only failure regression, compile and run against the same final library:

```powershell
& "$ndkBin/bin/aarch64-linux-android28-clang++.cmd" -std=c++17 '-Inative/llama.cpp/include' '-Inative/whisper.cpp/ggml/include' native/tests/vulkan_failure_retry_test.cpp "$nativeLibs/libjlexa_native.so" -o artifacts/cpu-regression/vulkan_failure_retry_test
adb -s $serial push artifacts/cpu-regression/vulkan_failure_retry_test /data/local/tmp/jlexa_vulkan_failure_retry_test
adb -s $serial shell chmod 755 /data/local/tmp/jlexa_vulkan_failure_retry_test
adb -s $serial shell 'LD_LIBRARY_PATH=/data/local/tmp timeout 20 /data/local/tmp/jlexa_vulkan_failure_retry_test /sdcard/Models/llm/qwen2.5-1.5b-instruct-q4_k_m.gguf'
```

Expected: two `ATTEMPT` errors, `Repeated unsupported shader failures returned: 2`, and exit code zero. A timeout is a failure. This negative fixture intentionally requests an unsupported kernel and is specific to the tested Adreno driver/model; it is not a general test for other GPUs.

`native/tests/vulkan_compat_test.cpp` additionally checks device/pipeline scoping, SPIR-V loop-mask preservation, idempotence, and malformed/truncated instruction handling. All harnesses read existing model files without modifying app conversations, runtime preferences, lessons, or models.
