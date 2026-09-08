# MP3 cut playback alignment — Pixel 6, 2026-09-08

## Report and reproduced cause

The saved 42.000–49.000 s cut in `ted-career-safety` had the transcript
“Probably I'm the only one in the room with a serious profession.” Playback
also included part of the following sentence, and Next repeated that content.
The waveform showed the requested timeline and did not expose this discrepancy.

Validation used Pixel 6 `25311FDF6004PR` (Android 16), the existing lesson and
Tiny English Whisper model. No Honor device was used. The user's original
lessons, cuts, models and settings were retained.

Two independent measurements separate recognition from playback:

* Current `AudioRangeDecoder` extraction of 42–49 s correlates with a sequential
  full-file PCM reference at exactly 42.000 s (0 ms offset, correlation 0.99817).
  Recognition of that extraction contains only the profession sentence.
* A scrcpy recording of the installed app's actual audio output matches source
  44.668–51.568 s over continuous 100 ms blocks (correlation mostly 0.97–0.996),
  while the UI replays nominal 42–49 s and stops at 49. The actual audio was
  approximately 2.6 s ahead of the displayed timeline. Playback duration was
  normal; this was a seek-position error, not a multi-second delayed Stop.
* Next, nominal 49.310–57.000 s, actually played approximately 50.318–58.054 s.
  The two actual audio ranges overlapped by about 1.34 s. Different offsets at
  different positions rule out a fixed offset correction.

Host-only recordings, raw timestamp probes and correlation JSON are under the
ignored `test_artifacts/` directory. They include
`pixel-before-replay-full.mkv`, `pixel-before-replay-alignment-fine.json` and
`whisper-timestamp-mp3-alignment.json`. The source audio is not redistributed.

## Change

Select the official `audioplayers_android_exo` 0.1.4 Android implementation.
The existing Dart AudioService, controls, segmentation, transcripts and other
platform implementations retain their APIs and behavior. No plugin fork or
additional playback framework was introduced.

Media3 distinguishes CBR `Info` from VBR `Xing` and uses a constant-bitrate
seeker for `Info` to avoid its low-resolution table of contents:
[Media3 1.9.0 MP3 extractor](https://github.com/androidx/media/blob/1.9.0/libraries/extractor/src/main/java/androidx/media3/extractor/mp3/Mp3Extractor.java#L598-L607).
Android's MediaPlayer MP3 extractor uses the Xing/Info seeker and does not use
the requested seek mode to improve its time-to-byte mapping:
[Android 16 MP3 extractor](https://android.googlesource.com/platform/frameworks/av/+/android-16.0.0_r1/media/module/extractors/mp3/MP3Extractor.cpp#486).

The supplied file was fully parsed: 38,481 MPEG-1 Layer III frames (including
the header frame), all 320 kbps, 44.1 kHz stereo; `Info` marker at byte 174,
first frame at byte 138. Applying Android's TOC interpolation to requested 42 s
predicts byte 1,783,867 and an actual frame at 44.591 s, independently reproducing
the recorded error. The fix uses the official implementation without custom
index flags or a vendored dependency.

The two players report a 47 ms difference in total duration from padding.
Whisper window sessions now use the persisted lesson timeline for cache
identity, preventing this small decoder difference from discarding completed
recognition when toggling the feature or reopening a lesson. The existing
correction for missing or substantially incorrect stored durations remains.
Regression tests cover both the 47 ms cache case and an initially zero duration.

The settings widget test now uses an isolated SQLite database and waits for
the actual setting write instead of a fixed 100 ms delay; it also verifies the
persisted setting. This addresses a reproduced intermittent test failure.

## Verification

Recorded output after the Android implementation change:

| Action | Requested source range (s) | Measured source audio (s) |
| --- | --- | --- |
| Replay profession sentence | 42.000–49.000 | approximately 42.051–49.166 |
| Next / father sentence | 49.310–57.000 | approximately 49.330–57.071 |
| Sentence crossing minute boundary | 57.000–61.000 | approximately 57.040–61.053 |
| Late-file replay | 943.699–946.159 | approximately 943.710–946.265 |

Repeat returned to source 57 s on three successive runs without accumulated
drift; two cycles completed and the third was manually stopped near its end.
WAV and short MP3 playback, Auto-stop, continuous playback through EOF and Play
after EOF were also exercised on the existing `jlexa-vad-test` lessons.

These are output recordings correlated with sequential reference PCM, not just
UI timestamp comparisons. Signal edges use a 2-LSB threshold; Opus encoding,
Android's audio sink and fade-out make them approximate. The existing Dart
boundary timer still permits about 50–170 ms of measured tail overshoot. This
change removes the multi-second seek error; it does not claim sample-accurate
native clipping or perfect linguistic Whisper boundaries. The tested MP3 is CBR;
this is not an exhaustive validation of arbitrary VBR encoders.

Final host checks: `flutter analyze` reported no issues (zero errors/warnings),
and `flutter test --concurrency=1` passed all **398 tests**. The first full run
exposed the settings test's 100 ms assumption; after its fix and the cache
regressions, the final full run passed in 83 seconds.

A further recording of the final signed APK (`pixel-final-replay.mkv`) measured
the first cut at approximately **42.012–49.088 s**. All 70 complete 100 ms blocks
had correlation at least 0.9796 with the reference, confirming that the final
artifact retains the playback correction.

The final signed release built in 60.5 seconds and was installed on Pixel with
data preserved. Force-stop/relaunch restored the existing first-window cuts and
cached transcript without a new window-0 recognition request. The phone was
left paused at 42 s with the profession transcript visible, Whisper-assisted
segmentation ON, Auto transcript OFF, Repeat OFF and Auto-stop ON. Final PID:
32432. No new crash-buffer entries occurred during the corrected-release checks.

* Fixed artifact: `release/app-release.apk`, 115,686,715 bytes.
* APK SHA-256: `7A2198C648C14164EF3C159D03086CF4799E225C34BD5DD1419B554FB31E777D`.
* Installed `base.apk` SHA-256 matches the fixed artifact.
* `apksigner verify --verbose --print-certs`: verified, v2 true.
* Signer SHA-256: `6890d48ab8f1b2608392fad0f9dffad9d77f1257554b17e2a866a7d2e7d116da`.
* The existing upstream flutter_tts future Kotlin-plugin warning remains;
  release compilation succeeds.
* Automatic approval review rejected deletion of the two duplicate APKs under
  `app/build/app/outputs/` (`blocked by policy`), including the attempt using
  their explicit verified paths. They remain; the fixed release is current.
