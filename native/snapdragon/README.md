# Snapdragon CPU plugin

This is a small, importable CPU backend for the Snapdragon 8 Elite (SM8750)
phone tested in `docs/qa-snapdragon-backend-2026-09-07.md`. It reuses JLexa's
pinned llama.cpp engine, model loader, sampler and stable C ABI. It compiles
GGML's existing ARM dot-product, integer matrix-multiply and FP16 kernels
instead of the generic ARMv8 instruction baseline. It does not change model
weights, sampling, prompts or the app's built-in Vulkan compatibility path.

The plugin checks Linux HWCAP flags before creating the engine. Missing
dotprod, i8mm or vector FP16 produces an ordinary plugin creation error.
The guard and ABI adapter are compiled for baseline ARM64; only GGML CPU
kernels use the stronger instruction set. This build has CPU only, uses
the user's requested thread count, and accurately reports effective runtime.
Other CPUs with those capabilities can load it, but performance claims are
limited to the tested phone.

## Build and import

From the repository root in PowerShell:

```powershell
./native/snapdragon/build.ps1
```

The script uses Android NDK 28.2.13676358 and CMake 3.22.1 from the Android SDK,
keeps its independent build cache under `native/snapdragon/build/`, and writes
`release/jlexa-snapdragon-plugin.so`. It statically links C++ and GGML, disables
OpenMP (GGML retains its own worker pool), exports the inference and optional
benchmark APIs, and aligns ELF segments to 16 KB. Only Android system libraries
are needed; no dependency files need importing.

Copy that `.so` to the phone and use Settings → Backend Plugins → Import .so.
JLexa copies it to private read-only storage through the existing importer.
Choose CPU (or Auto, which resolves to CPU in this plugin). The model and
thread count continue to come from the existing app settings. The built-in
backend remains available to return to GPU operation.

## Reproduce native measurements

`build.ps1 -Baseline` additionally produces
`release/jlexa-arm64-baseline-plugin.so`, an otherwise identical CPU plugin
compiled for generic ARMv8. This isolates the instruction-set optimization;
it is a measurement fixture, not another required app dependency.

Compile `benchmark.cpp` with the NDK ARM64 compiler and `-std=c++17 -O2
-static-libstdc++ -Inative/plugin -ldl`. Push the executable and plugins to a
dedicated `/data/local/tmp/jlexa_snapdragon/` directory. Its arguments are:

```text
benchmark PLUGIN_PATH MODEL_PATH [THREADS=4] [BACKEND=cpu]
```

Each process performs one cold and three warm real translation benchmarks,
then cancellation and two ordinary-generation correctness checks. Benchmark
metrics use the same optional ABI as Settings: exact 100-token source, actual
templated prompt count, up to 100 output tokens, and synchronized native
prefill/decode time excluding callback/UI overhead. A terminal EOS may stop
generation before 100 tokens. Compare warm medians and retain the cold run
separately. The complete translation text is printed for review; the arithmetic
and short translation fixtures use assertions. This harness does not install
an APK or modify existing app/model data.
