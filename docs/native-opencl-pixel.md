# Experimental OpenCL on Pixel 6

## Result and supported scope

The Pixel 6 (`25311FDF6004PR`, Android 16) can now execute real OpenCL matrix multiplication through an app-owned, restricted Mali-G78 backend. This is an explicit experimental option. Auto continues to select Vulkan, then CPU. Explicit CPU selection retains an empty GPU device list and disabled GPU operation/KV offloading.

Supported GPU operations are contiguous Q4_K/Q6_K weights multiplied by contiguous F32 activations, with F32 output. Dimensions must meet the validated block/row alignment. Other tensor types and operations stay on CPU. KV cache and attention remain CPU resident. This is partial GPU computation, and may be slower than CPU.

The tested Qwen2.5 0.5B Q4_K_M file contains 133 Q5_0 tensors, 13 Q8_0 tensors, 12 Q4_K tensors, and 12 Q6_K tensors. The restricted backend therefore offloads only some matrices despite the model filename. Native allocation diagnostics show 68.97 MiB of OpenCL model buffers versus 394 MiB on CPU, an 11.25 MiB OpenCL compute buffer, and 49 scheduler graph splits. The dispatch log confirms actual GPU Q6_K operations; enumeration or a selected backend label alone is insufficient evidence of acceleration.

## Investigation

The device's `/vendor/etc/public.libraries.txt` exports `libOpenCL.so` and `libOpenCL-pixel.so`. The standard entry points are in `libOpenCL.so`; the latter library does not export `clGetPlatformIDs`.

The standalone capability probe reported:

| Property | Observed value |
| --- | --- |
| GPU | Mali-G78 r0p0 |
| Platform | ARM Platform |
| Runtime | OpenCL 3.0, driver build `v1.r54p1-12eac0.3979a5abbd708e71c87fdb7af36852c5` |
| OpenCL C versions | 1.0, 1.1, 1.2, 3.0 |
| Features | FP16, KHR subgroups, subgroup shuffle, integer dot product |
| Observed subgroup size | 16 |
| Maximum workgroup | 512 |
| Maximum single allocation | 4,294,443,024 bytes |
| FP32/FP16 arithmetic and subgroup reduction | Passed, all 256 output elements checked |

The legacy `CL_DEVICE_OPENCL_C_VERSION` string says 1.2; the complete version list includes 3.0. Treating the legacy string as the maximum supported language version would incorrectly reject this driver.

The prior build forced `GGML_OPENCL=OFF`. Simply enabling it would still fail: the pinned shared GGML implementation admits only Adreno/Intel. Its unmodified Q4_K kernel fails on Mali with `CL_BUILD_PROGRAM_FAILURE (-11)` because `N_SIMDGROUP`, `N_DST`, and `N_SIMDWIDTH` are undefined. Several host dispatch paths assume subgroup widths 32/64, including normalization scratch sizing, and eager kernel loading reaches unrelated vendor-specific kernels. Labeling Mali as Intel would leave these assumptions incorrect.

The backend documentation describes Adreno and some Intel support; it does not establish Mali compatibility. Android applications targeting API 31 or newer must also explicitly request vendor libraries in the manifest. [Upstream OpenCL documentation](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/OPENCL.md), [Android uses-native-library documentation](https://developer.android.com/guide/topics/manifest/uses-native-library-element).

## Bounded implementation

`native/bindings/make_opencl_mali_backend.py` generates the backend in the build directory from pinned Whisper/GGML sources. Source hashes reject an unreviewed vendor update. The vendor submodules remain unchanged.

The overlay:

- Accepts Mali-G78 only and advertises only the validated Q4_K/Q6_K matrix operations.
- Adds explicit Mali kernel branches with subgroup width 16, without defining Intel/Qualcomm extension support.
- Compiles only those two kernels at runtime and validates their subgroup sizes before use.
- Uses a small matrix dispatcher with bounded offsets and dimensions; other operations fall back through the GGML scheduler.
- Converts driver/program compilation failures into exceptions handled by the existing native bridge. Kernel setup cleans partial handles on failure, and cleanup does not throw.

`jlexa_opencl_api.cpp` resolves the optional vendor API with `dlopen`/`dlsym`, checks device support before backend registration, and retains the library for the backend lifetime. The APK fetches only pinned public Khronos headers. It does not distribute the phone's proprietary driver or introduce a `DT_NEEDED` dependency on `libOpenCL.so`. Missing drivers, entry points, and unsupported GPU families leave CPU/Vulkan available. The manifest requests `libOpenCL.so` with `required=false`.

The limited backend must keep KV on CPU. An early isolated experiment that retained GPU KV failed at scheduler reservation because the preallocated GPU cache could not execute `SET_ROWS`. Disabling KV offload for this backend resolved that failure. CPU and Vulkan retain their previous KV behavior.

## Native verification

Kernel-level validation compared the explicitly ported Q4_K/Q6_K kernels against GGML CPU reference quantization/dequantization and a double-precision host dot product. Twelve cases covered inner dimensions 256/1024/4096, matrices with 8/64 rows, and 1/7 activation columns. All passed; maximum scaled error was below `4.4e-5`, against a `1e-3` threshold.

The exact production native sources, compiled as an isolated library, passed:

- Three sequential Qwen generations: arithmetic `4`, translation `早上好。`, and relevant `say`/`tell` prose, including default Flash Attention settings.
- A fixed long prompt spanning more than one 512-token evaluation batch, answering `4`.
- Counting generation, cancellation after five token callbacks, the next generation, and model unload/reload.
- CPU regression with one scheduler split and no OpenCL compute buffer.
- Eight concurrent initialization callers under missing-driver and missing-entry-point simulations: one driver-open attempt, no backend registration, a useful unavailable reason, and no crash.
- Shared-library symbol inspection: no unresolved OpenCL symbols and no vendor OpenCL load dependency.

The integrated Gradle `:app:externalNativeBuildRelease` target also built successfully for ARM64 and x86_64. A smoke executable linked directly to its ARM64 `libjlexa_native.so` passed all three prompts separately in CPU, Vulkan, and OpenCL modes. CPU retained one graph split with no OpenCL compute buffer; OpenCL reported its real Q6_K dispatch and an 11.25 MiB compute buffer. Logs are in `artifacts/opencl-pixel/gradle-{cpu,vulkan,opencl}.txt`. The unstripped ARM64 library SHA-256 was `115835E480D4957C2FD84153470A67318D545FC3A1A39D39C55B142C5D443F78`.

These validate the supplied model/device and restricted operation scope. They do not establish semantic correctness of every answer or support for other Mali models/driver versions. Final packaged-APK and app-context verification is recorded in the root session log.

## Controlled performance sample

Same Pixel 6, model, seed 1234, temperature 0, context 2048, batch/microbatch 512, four CPU threads, and Flash Attention disabled. Each request starts with cleared inference memory. The long prompt repeats 24 fixed background sentences and ends with the same arithmetic question. All modes produced `4`; the counting request produced the same 69 token callbacks.

| Warm request | CPU | Experimental OpenCL | Vulkan |
| --- | ---: | ---: | ---: |
| Short arithmetic | 0.650 s | 0.748 s | 2.563 s |
| Long arithmetic | 9.295 s | 9.450 s | 20.198 s |
| Count 1–20 | 2.522 s | 4.889 s | 7.830 s |

This small sequential sample shows similar long-prompt cost to CPU and approximately twice the generation time for partial OpenCL. It also outperformed Vulkan in this fixture. Temperature, power state, concurrent work, other quantizations, and model dimensions can change the result; it is not a general backend ranking. Later production correctness runs occurred while other app testing resumed and are excluded from this performance table.

## Reproduction

Build the signed release through the repository workflow, then compile `native/tests/llama_cpu_smoke.cpp` or `native/tests/llama_backend_benchmark.cpp` against the packaged `libjlexa_native.so`, as in `native-cpu-regression.md`. Pass `opencl` as the backend argument. The benchmark includes cancellation/reset and reload checks. It runs in a separate process, reads the model, and does not install an APK or modify app data.

For isolated kernel verification, obtain Khronos OpenCL-Headers at commit `c4c8fd6f9556c92b212308880854e6294d61b314` and point the compiler's include path at its root. Then:

```powershell
$ndkBin = "$env:LOCALAPPDATA/Android/Sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/windows-x86_64/bin"
$headers = 'artifacts/opencl-pixel'
& native/tests/make_mali_kernel_probes.ps1
& "$ndkBin/aarch64-linux-android28-clang.cmd" -std=c11 -Wall -Wextra -Werror "-I$headers" native/tests/opencl_capability_probe.c -ldl -o artifacts/opencl-pixel/opencl_capability_probe
& "$ndkBin/aarch64-linux-android28-clang.cmd" -std=c11 -Wall -Wextra -Werror "-I$headers" -Inative/whisper.cpp/ggml/src -Inative/whisper.cpp/ggml/include native/tests/opencl_mali_matvec_probe.c -ldl -lm -o artifacts/opencl-pixel/opencl_mali_matvec_probe
```

Push the probes and generated kernel directory to a diagnostic directory under `/data/local/tmp`, mark the executables executable, and run the matvec probe with three arguments: packaged reference library, generated Q4_K kernel, generated Q6_K kernel. Supply the packaged runtime dependencies via `LD_LIBRARY_PATH` as in the CPU fixture. The capability probe optionally takes a library name and an original kernel file to reproduce the upstream compilation failure; its exit status reflects basic device/FP32 functionality, while optional feature/kernel results are printed separately.

`native/tests/opencl_loader_failure_test.cpp` compiles with `native/bindings/jlexa_opencl_api.cpp`, the Khronos headers, and GGML headers. It supplies diagnostic loader/registry stubs. Run once with no arguments and once with `missing-symbol`; both must report PASS. These stubs exist only in the test executable.
