# Whisper segment decoding and Collection clips — Pixel 6

## Diagnosis and measured result

Device: Pixel 6 `25311FDF6004PR`, Android 16. Source: the supplied TED MP3 at `/sdcard/Download/JLexaTest/ted-career-safety.mp3`, approximately 16 minutes 45 seconds. Whisper model: `/sdcard/Models/whisper/ggml-tiny.en.bin`, four CPU threads.

The old Kotlin transcription path decoded the entire file, calculated unused waveform peaks, and only then copied the requested cut. A standalone copy of the original decoder took **155,270 ms**, producing 16,082,327 valid samples, before selecting the 25.999–29.250-second cut. It allocated 16,099,069 samples; full-audio transcription also mistakenly passed that spare capacity to JNI. The new bridge passes `validSampleCount` for full-audio requests.

| Operation | Measured time |
| --- | ---: |
| Old whole-file decode before selecting the 3.251-second cut | 155,270 ms |
| New correctly aligned decode of the same cut | 277 ms |
| Whisper Tiny model load | 101 ms |
| Whisper inference, first request | 1,338 ms |
| Whisper inference, second request | 1,276 ms |
| New decode at 990.123–993.874 seconds | 1,689 ms |

For the short cut, separate decode plus warm inference measurements total approximately **1.55 seconds**, compared with roughly 156.5 seconds on the old path. These are diagnostic measurements, not an app interaction latency guarantee. Both native inference requests returned `So what would be your reaction to ideas like that?`.

The Settings Vulkan/OpenCL selection belongs to the language model. Whisper explicitly uses `cparams.use_gpu=false`. In the pinned Whisper source, that disables GPU/IGPU backend initialization and GPU weight buffers. The native test registered the app's available GPUs first, then loaded Whisper; Whisper still reported CPU model storage and no GPU backend. No Whisper GPU setting or vendor source was changed.

## Implementation and alignment

`AudioRangeDecoder` supports a bounded interval on the original audio timeline:

- PCM WAV files use direct header parsing and byte seeking. Mono conversion and interpolation are anchored to the exact requested 16 kHz sample grid, including fractional positions and buffer boundaries.
- Compressed files decode a short prefix to calibrate the codec's gapless timestamp offset. The codec is then flushed, the extractor moves to 500 ms before the requested interval, and only preroll plus the requested interval is decoded. AAC's valid negative priming timestamps are accepted.
- Indexed formats use `MediaExtractor.seekTo(..., SEEK_TO_PREVIOUS_SYNC)`. Android's MP3 seek approximation was about 420 ms wrong on the TED source, so MP3 advances through compressed packet timestamps instead. This reads the compressed prefix without decoding or retaining its PCM. Its remaining scan cost is **O(position)**; the late-file measurement above includes it.
- PCM timestamps and sample counts trim the result to the requested interval. EOF shortens the clip to available samples. Decoder stalls and cancellation terminate with cleanup rather than leaving codec handles active.

The gapless calibration matters: using packet timestamps alone introduced another 46.44 ms discrepancy on this MP3. The corrected selected-cut PCM had **0.203% scaled RMS error** against the original sequential decoder's slice; remaining differences are interpolation across the old decoder's buffer boundaries. A cross-correlation with an independent full-file PCM reference placed the late clip at **990123.0 ms**, exactly its requested start. That independent reference uses a different stereo gain/resampler, so it is used for temporal alignment, not sample equality.

API rationale: Android documents [extractor seeking to sync samples](https://developer.android.com/reference/android/media/MediaExtractor#seekTo(long,%20int)) and exposes decoded output timing through [BufferInfo.presentationTimeUs](https://developer.android.com/reference/android/media/MediaCodec.BufferInfo#presentationTimeUs). Sample trimming is still required after seeking.

The existing full-audio voice transcription path remains available. Per-cut requests now require valid endpoints, preserve absolute transcript/token offsets, log decode and inference separately, and pass only valid samples. Cancellation is reset before dispatch so a subsequent immediate Cancel cannot be erased by the worker. Terminal responses release their request ownership before returning; late progress is filtered by request ID.

## Collection export API

Channel: `com.jlexa.app/whisper`.

```text
exportAudioClip({
  audioPath: String,
  startMs: int,
  endMs: int,
  outputPath: String
}) -> {path: String, durationMs: int, sampleRate: 16000}
```

Inputs are local filesystem paths and require `0 <= startMs < endMs`. `path` is the exact caller-supplied `outputPath`. The destination must differ from the source and must not already exist. No Whisper model or native inference library is needed to export.

The result is an independent mono 16 kHz PCM16 WAV. Export writes a unique sibling temporary file, flushes and syncs it, then atomically renames it. Failure/cancellation removes that temporary file. The source is read only; source deletion or later cut edits cannot change the exported bytes. `durationMs` describes the actual exported samples, including EOF clamping. Invalid arguments use `INVALID_ARGS`; decode/write failures use `EXPORT_ERROR` through the channel.

## Verification and reproduction

No APK was installed and no app UI was operated by these native fixtures. The root task performs final app/Kotlin build and in-app verification.

- `AudioRangeUnitProbe`: 8/16/44.1/48 kHz stereo floating-point WAV, an odd-sized metadata chunk, analytic sample-by-sample resampling, exact range duration, EOF/beyond-EOF, invalid ranges, cancellation, export round trip, and temporary-file cleanup: **PASS**.
- `AudioRangeAlignmentProbe`: synthesized AAC/M4A and VBR MP3, compared with the original sequential decoder at the beginning, an offset beginning, middle, and end extending past EOF. All eight ranges passed, scaled RMS error **0.056–0.0922%**. Mid-decode cancellation passed for both formats.
- `AudioRangeProbe`: selected TED cut and late TED cut, PCM/WAV header/sample length, existing-destination rejection, same-source rejection, cancellation cleanup: **PASS**.
- `whisper_segment_smoke.cpp`: two real CPU transcriptions, pre-cancelled request, reset and successful next request: **PASS**. The expected pre-cancel case prints a Whisper `failed to encode` diagnostic; it is not a native abort.

Raw logs are under `artifacts/whisper-range/`: `baseline.txt`, `range-ted.txt`, `range-ted-late.txt`, `unit-tests.txt`, `alignment-aac.txt`, `alignment-mp3.txt`, and `whisper-ted.txt`.

From the repository root, compile the standalone Android probe using the cached Kotlin compiler, Android SDK, and bundled Android Studio JBR:

```powershell
$audio = 'app/android/app/src/main/kotlin/com/example/local_ai_app'
& native/tests/build_audio_probe.ps1 -Sources @(
  "$audio/AudioDecoder.kt", "$audio/AudioRangeDecoder.kt", "$audio/AudioClipExporter.kt",
  'native/tests/AudioRangeProbe.kt', 'native/tests/AudioRangeUnitProbe.kt',
  'native/tests/AudioRangeAlignmentProbe.kt'
)
adb -s 25311FDF6004PR push artifacts/whisper-range/probe/classes.dex /data/local/tmp/jlexa_audio_range.dex
adb -s 25311FDF6004PR shell 'CLASSPATH=/data/local/tmp/jlexa_audio_range.dex app_process /system/bin com.example.local_ai_app.AudioRangeUnitProbe /data/local/tmp/jlexa-audio-unit'
```

Generate compressed fixtures, push them, and run `AudioRangeAlignmentProbe` once per source:

```powershell
ffmpeg -hide_banner -loglevel error -f lavfi -i 'aevalsrc=0.25*sin(2*PI*(220*t+7*t*t))|0.15*sin(2*PI*(330*t+11*t*t)):s=44100:d=12' -c:a aac -b:a 128k -y artifacts/whisper-range/range-fixture.m4a
ffmpeg -hide_banner -loglevel error -i artifacts/whisper-range/range-fixture.m4a -c:a libmp3lame -q:a 3 -y artifacts/whisper-range/range-fixture.mp3
adb -s 25311FDF6004PR push artifacts/whisper-range/range-fixture.m4a /data/local/tmp/jlexa-range-fixture.m4a
adb -s 25311FDF6004PR push artifacts/whisper-range/range-fixture.mp3 /data/local/tmp/jlexa-range-fixture.mp3
adb -s 25311FDF6004PR shell 'CLASSPATH=/data/local/tmp/jlexa_audio_range.dex app_process /system/bin com.example.local_ai_app.AudioRangeAlignmentProbe /data/local/tmp/jlexa-range-fixture.m4a'
adb -s 25311FDF6004PR shell 'CLASSPATH=/data/local/tmp/jlexa_audio_range.dex app_process /system/bin com.example.local_ai_app.AudioRangeAlignmentProbe /data/local/tmp/jlexa-range-fixture.mp3'
```

For a source-specific export use `AudioRangeProbe <source> <startMs> <endMs> <newOutput.wav> [full-decode-reference.f32be]`. Its optional reference is a big-endian float32 slice from the sequential decoder. To time inference, build `native/tests/whisper_segment_smoke.cpp` against the release `libjlexa_native.so` using the NDK command pattern in `native-cpu-regression.md`; run it with `<ggml-tiny.en.bin> <exported.wav>` and the packaged runtime dependencies in `LD_LIBRARY_PATH`.

Limits: validated on this Pixel's codecs and supplied/synthesized MP3, AAC/M4A and PCM WAV. Other codecs/devices may differ. Files changing sample rate midstream are rejected. MP3 seeking retains compressed-prefix scanning. The resampler is linear, consistent with the existing Whisper input path; Collection exports prioritize standalone compatibility over preserving original compressed encoding/stereo. Acoustic recognition quality remains model dependent.
