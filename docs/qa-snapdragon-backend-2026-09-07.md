# Snapdragon 8 Elite CPU plugin validation — 2026-09-07

## Device and implementation

The connected Honor PTP-AN00 reports `ro.soc.model=SM8750`, manufacturer `QTI`,
six CPUs with maximum frequency 3,532,800 kHz and two at 4,320,000 kHz. Its
CPU feature flags include `asimddp`, `i8mm` and `asimdhp`. The previously
documented GPU is Adreno 830. Testing used wireless ADB serial
`adb-AJTLVB4B05002604-ROpSXf._adb-tls-connect._tcp`.

`native/snapdragon/` builds a CPU-only JLexa plugin using the same pinned
llama.cpp and shared whisper GGML revisions as the app. The optimized build
uses `-march=armv8.2-a+dotprod+i8mm+fp16` for GGML CPU kernels, enabling the
existing quantized dot-product/matrix-multiply implementations and CPU repack.
Disassembly confirms ARM `sdot` instructions. No vendored source or Vulkan
shader was changed. A baseline-compiled entry point checks Linux HWCAP flags
before creating the engine; unsupported instruction sets produce an error.

The C ABI adapter, model path handling, CPU isolation, sampling, cancellation,
and optional benchmark API are reused from the app. The plugin respects the
requested thread count. OpenMP is disabled for both measurement builds;
GGML's own worker pool remains active. C++ is linked statically. Imported
inference needs only Android `liblog`, `libm`, `libdl` and `libc`.

This is a CPU optimization. It does not claim Adreno GPU, OpenCL, or NPU
acceleration. The built-in backend's existing Adreno correctness workaround
and GPU selections remain available by returning to the built-in backend.

## Controlled native comparison

The dedicated `native/snapdragon/benchmark.cpp` uses `dlopen` and both stable
plugin entry points. Every process performs one cold and three warm runs,
then cancellation and ordinary-generation correctness checks. Both builds
use context 2048, batch/microbatch 512, Flash Attention off, temperature 0,
seed 1234 and an explicit CPU backend. The baseline differs only in compiled
CPU architecture (`armv8-a` versus the optimized flags).

The shared native benchmark constructs a source of exactly 100 model tokens,
asks for English-to-Chinese translation, and caps generated output at 100
tokens. On these Qwen vocabularies the templated prompt contains 121 tokens.
The recorded prefill count is therefore 121, not 100. Timing surrounds
synchronized native inference, excludes callbacks/UI and model loading, and
counts actual decode evaluations. EOS can finish a run before the cap.

Models already on the phone were read without modifying them:

| Model | Bytes | SHA-256 |
| --- | ---: | --- |
| Qwen2.5 1.5B Instruct Q4_K_M | 1,117,320,736 | `6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e` |
| Qwen2.5 3B Instruct Q4_K_M | 2,104,932,768 | `626b4a6678b86442240e33df819e00132d3ba7dddfe1cdc4fbb18e0a9615c62d` |

Warm medians, tokens/second:

| Model | Backend build | Threads | Prefill | Decode |
| --- | --- | ---: | ---: | ---: |
| 1.5B | Generic ARMv8 CPU baseline | 4 | 25.104 | 18.575 |
| 1.5B | Snapdragon CPU | 4 | 96.779 | 32.402 |
| 1.5B | Snapdragon CPU | 6 | 139.874 | 36.521 |
| 3B | Generic ARMv8 CPU baseline | 4 | 11.926 | 9.661 |
| 3B | Snapdragon CPU | 4 | 48.654 | 17.128 |

The matched four-thread runs improved prefill/decode by **3.86× / 1.74×** on
1.5B and **4.08× / 1.77×** on 3B. This compares two otherwise identical native
CPU builds, not a claim that the APK's built-in Vulkan backend was slower.
Six threads performed better in this sample, but the plugin does not silently
replace a user's requested thread count.

A later, isolated 1.5B four-thread repeat after the longer test sequence had
warm medians **88.984 / 30.520**, still faster than the baseline. Individual
warm results ranged from 52.260–98.234 prefill and 22.058–31.064 decode.
Battery temperature rose from 30 °C early in testing to 35 °C during the
sequence; CPU clocks, thermal policy and foreground activity were not fixed.
Treat these as measurements on this phone, not guaranteed sustained speeds.

## Correctness and cancellation

All five primary configurations and the final isolated repeat returned
success on every full benchmark, produced nonempty Chinese translation,
reported source=100 and prompt=121, and stayed within the 100-token cap.
Generated/decoded counts were 98 for the 1.5B baseline, 90 for optimized 1.5B,
96 for the 3B baseline, and 94 for optimized 3B. Floating-point kernel changes
can change greedy output; the translations were not byte-identical.

Each process then stopped a benchmark after its fifth output callback. All
returned cancellation code 1, and resetting cancellation immediately allowed
both ordinary-generation checks to pass:

- `What is 2 plus 2? Reply with only the number.` → `4`
- `Translate into Chinese: Good morning.` → `早上好。`

For example, the optimized 3B translation began:

> 每天早晨，一个年轻的学生都会穿过安静的公园去图书馆，在那里她阅读科学和历史书籍，把不认识的单词写在小笔记本上，并练习向一个正在学习相同语言的朋友解释新的想法

Its answer continued through the practice/conversation and future-meetings
ideas without the earlier unrelated/repetitive native corruption. These
focused fixtures do not establish general translation accuracy: some small
model paraphrases add or omit details, and the source is truncated at a token
boundary for a fixed-size performance workload.

## Artifact and handoff

- Build command: `./native/snapdragon/build.ps1`.
- Comparison fixture build: `./native/snapdragon/build.ps1 -Baseline`.
- Final plugin: `release/jlexa-snapdragon-plugin.so`, **4,136,496 bytes**.
- SHA-256: `264C75E5CBD1EECEBFF20E2FC928A826C0052FAB189A7268400DB88AAEF08E35`.
- ELF64 AArch64; 16 KB load-segment alignment; only the inference and optional
  benchmark entry points are exported.
- Final source rebuild reported `ninja: no work to do`; this is the same
  binary measured on the phone.
- Pushed import source:
  `/sdcard/Download/JLexa-snapdragon/jlexa-snapdragon-plugin.so`.

The native test executable and diagnostic plugin copies were kept under
`/data/local/tmp/jlexa_snapdragon/`. No APK was installed by this subtask, and
no existing application settings, conversations, downloaded models or model
files were changed. The main task owns final signed APK validation and the
new Benchmark UI/import verification. The source in Downloads is only an
import source; JLexa's importer copies it into private read-only storage before
execution.
