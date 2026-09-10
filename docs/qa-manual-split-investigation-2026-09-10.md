# Manual split playback overlap — 2026-09-10

## Result

Confirmed real overlapping playback on the user's wireless Honor PTP-AN00, in
`Why do we celebrate incompetent leaders?` near 1:37. The old Media3 MP3 seeker
uses the file's coarse Xing seek table. Different seeks establish different
frame/time offsets, so a common saved boundary does not guarantee a common
actual audio boundary. The fix indexes actual MP3 frames instead.

No segmentation or transcript edits were made by this task. The earlier
100 ms post-split rewind hypothesis does not explain the repeated overlap and
that behavior was not changed.

## Device evidence before the fix

- Wireless serial: `adb-AJTLVB4B05002604-ROpSXf._adb-tls-connect._tcp` (Honor).
- Lossless FLAC playback capture: `test_artifacts/split-honor-pair.mka`.
- Correlation against independently decoded full-source PCM, in 50 ms blocks:
  first selected cut contained source **94.249–98.099 s**; the next contained
  **97.386–106.086 s**. At least **0.713 s** of the same audio was repeated.
- Original state: Auto-stop ON, Repeat OFF, Auto transcript OFF. These modes
  were restored; the first cut is selected and paused at its end around 1:37.
  No installation, model change, transcription, or cut edit was performed.
- Before the wireless device appeared, one replay was captured on the USB Pixel.
  Its saved left cut `[88130,98338)` and right cut `[98338,112015)` shared an exact
  boundary; the left replay nevertheless mapped to about 89.581–99.658 s in the
  source. Only a read-only DB/audio copy and playback were performed there.
  Pixel operations stopped when the other active task requested exclusive use.

The reference source copied read-only from Pixel is a 23,717,985-byte VBR MP3, approximately 972.434 seconds
long. Its Xing header starts at byte 173, advertises 37,226 frames, and contains
only 100 TOC entries. An interpolation across this coarse table does not count
actual variable-size frames. Seeking from separate cut starts can therefore
move or repeat whole words even when the displayed millisecond ranges touch.
Its decoded audio matches the Honor recording. Honor's non-debuggable app
prevented direct access to its private database/source file; byte-for-byte
identity of the two imported files was not independently established.

## Fix

`ExoPlayerWrapper` replaces only the MP3 extractor, for both file/URL and byte
sources. Other extractors and existing clipping/playback modes stay in place.
`JlexaIndexedMp3Extractor` is an Apache-2.0-licensed copy of Media3 1.9.0's MP3
extractor with three focused changes: class name, default index flag, and
choosing the frame index even when header metadata claims to be seekable.

Simply setting upstream `FLAG_ENABLE_INDEX_SEEKING` is insufficient in 1.9.0:
upstream uses it only when the header map is **unseekable**. The tested file has
a seekable but approximate Xing map. Upstream provenance and license are
recorded in the adapter README and `LICENSE.media3`.

Index construction reads compressed frames without decoding or rewriting the
file. Cold seeks can read the prefix up to the target; rebuilt clipped sources
currently rebuild their index. Existing codec-frame endpoint granularity is
not converted to sample-accurate PCM clipping by this change.

## Independent computer verification

- Native JUnit tests execute actual Media3 extractors, input streams, and seek
  maps. Synthetic MPEG frames include identities that independently establish
  their exact source times. The stock extractor reproduces errors exceeding
  100 ms with coarse Xing metadata. The fixed extractor passes cold, adjacent,
  backward, repeated, late, and CBR Info-header cases. All **3 tests pass**;
  timestamp discrepancies are below 10 microseconds (integer rounding).
- A separate temporary Android probe in `JLexa_Split_QA_20260910` plays the actual
  reported MP3 using stock then fixed extractors, through Media3 decoding and
  the same zero-start clipping configuration. It does not replace the user's
  app or use another task's Pixel.
- Lossless recording: `test_artifacts/split-native-before-after.mka`.
  Four runs use `[88.130,98.338)` and `[98.338,112.015)`, first stock then fixed.
  Analysis and buffering events are retained alongside the recording.
- Strongly matched source-audio blocks in that recording:

  | Playback | Left cut | Right cut | Repeated source interval |
  |---|---|---|---|
  | Stock | 89.599–99.699 s | 97.722–111.322 s | about 1.977 s |
  | Indexed | 88.208–98.258 s | 98.347–111.997 s | none in matched blocks |

  Indexed source preparation took approximately 360 ms and 288 ms in this
  emulator run. These are observations for this file/device, not performance
  guarantees. The small unreported edges between correlation blocks are not
  evidence of missing audio or a sample-accurate gap.
- Recording comparisons use 50 ms correlation blocks and audio-output captures;
  they demonstrate removal of second-scale overlap, not exact PCM sample trims.

## Shared-workspace handling

The other active task owns Whisper long-cut processing and temporary
`qa_probe.dart` / `qa_raw` diagnostics. Those files are not part of this commit.
An initially staged foundation-import cleanup was withdrawn after coordination.
The earlier preliminary release rebuild was not a completed fix or a final
release. The owning task has now removed its temporary diagnostics. Final
validation and artifact details are recorded below after the shared build.

## Final validation and release

The final shared-workspace checks were run once in coordination with the active
Whisper task to avoid concurrent Flutter/Gradle output generation. Logs are in
`artifacts/long-sentence-small/{analyze,tests,build,signature}.log` and were
independently inspected by this task:

- `flutter analyze`: no issues (6.7 s).
- `flutter test --concurrency=1`: **451 passed**, zero failures (122 s).
- `flutter build apk --release`: succeeded (49.8 s), release signing from
  `app/android/key.properties`. Temporary diagnostic sources were removed first.
- Native MP3 regression suite: **3 passed**, zero failures.
- This task independently verified `release/app-release.apk` with apksigner:
  signature scheme v2 verified; signer SHA-256
  `6890d48ab8f1b2608392fad0f9dffad9d77f1257554b17e2a866a7d2e7d116da`.
- Fixed artifact: **115,703,179 bytes**; SHA-256
  `5F888A288216A76567DCAF7BEB245F3E2E967387EE65045B5CF875B18ACA8F5A`.
  Its hash matches the final Flutter build output. Release R8 mapping confirms
  `JlexaIndexedMp3Extractor` is included in the optimized APK.
- The other task installed this combined release on Pixel; this task did not
  install or validate the fixed release on Honor. Honor remains on its existing
  version. The independent emulator validates the native playback change.
- The temporary native-probe APK was removed and the temporary emulator stopped.
  Previously policy-blocked duplicate app/build APK cleanup was not retried.
  Existing flutter_tts compatibility and Java native-access warnings remain.
