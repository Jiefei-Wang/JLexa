# Waveform visibility and editing — 2026-09-07

## Findings and changes

The old painter used amplitude 0.25 to choose blue versus pale gray. This was a color threshold, not a signal gate. Its linear scale and three-pixel minimum made many quiet nonzero peaks look like silence. A separate review decoded the supplied 16:45 TED MP3 and compared stereo-average peaks with the maximum absolute channel peak: no audible passage was zeroed by the averaging in this sample. The quiet-speech display fix does not require changing extraction or VAD.

- The local view spans 20 seconds around the playhead and is titled **Local Window**.
- The target is 160 bars per window instead of 80. Fixed 125 ms buckets include all intersecting source peak intervals; scrolling changes their positions, not their samples or amplitude.
- All bars are neutral gray, 1.25 logical pixels wide. A fixed square-root height scale exposes quiet sound without per-window normalization or changing the raw values used for segmentation.
- Segment shading stays visible behind the opaque gray bars. The red playhead remains visible.
- Boundary lines and their touch targets exist only while Edit is enabled. Overlapping targets on short cuts are divided at the midpoint so the start and end remain independently draggable at the longer timescale.

Audio extraction, cache format, automatic segmentation, saved boundaries and transcript invalidation rules were not changed.

## Validation

- `flutter analyze`: no issues found.
- `flutter test --concurrency=1`: 256 passed, zero failed (66 seconds).
- Regression coverage verifies fixed-grid scrolling, 160 bins, a retained 0.001 peak, quiet-versus-silent painted height, uniform gray/thin strokes, hidden/visible handles, exact shade alignment and independent dragging of a 400 ms segment.
- Pixel 6 `25311FDF6004PR`: Flutter hot reload succeeded; the supplied TED lesson shows the 00:17–00:37 window at 00:27, denser gray bars and no handles when Edit is off. Enabling Edit displays the actual visible boundary. No test boundary edits or Redo were performed on this lesson.
- Final signed upgrade succeeded with `adb install -r`; release UI at 00:29 shows the 00:19–00:39 window and hidden handles with Edit off. PID 20503; no new crash entries. Existing lessons and models retained.

## Signed release

- `flutter build apk --release`: succeeded (60.3 seconds); temporary debug signing configuration was removed before building.
- `release/app-release.apk`: 94,947,605 bytes.
- APK SHA-256: `C5D6D9987082661A23AB26BEAF81D017A7B6CE6E63558FC564D280D45A4C83CD`.
- `apksigner verify --verbose --print-certs`: verified, v2 true. Signer SHA-256: `68:90:D4:8A:B8:F1:B2:60:83:92:FA:D0:F9:DF:FA:D9:D7:7F:12:57:55:4B:17:E2:A8:66:A7:D2:E7:D1:16:DA`.
- Existing upstream flutter_tts future Kotlin compatibility notice remains; the current release builds successfully. Prior policy-blocked duplicate APK-output deletion was not retried or bypassed.

Screenshots: [normal mode](images/qa-waveform20-locked.png), [editing mode](images/qa-waveform20-edit.png).
