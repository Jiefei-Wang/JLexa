# Segment transcription, Collection, and automatic stopping

## Requested behavior

- Transcribe only the selected segment without decoding the entire lesson first.
- Save the visible transcript and a standalone audio excerpt with **Add to Collection**. Browse and play clips under **Study → Collection**.
- Replace the transcript word-tapping hint with the collection action; individual words remain tappable.
- Add **Auto-stop at cut end** after Repeat. It starts enabled. Repeat takes precedence; with both options disabled, playback continues across cuts and gaps.

## Implementation and checks

The old transcription path decoded all 16:45 of the supplied TED MP3, computed an unused waveform, and only then sliced the requested PCM. The native range decoder now prepares the selected interval with decoding preroll and an absolute sample grid. Android MP3 seeking required an additional timestamp calibration and compressed-packet scan to preserve alignment. Whisper uses CPU; the Vulkan setting controls AI text generation. Native timing and format/cancellation checks are documented separately in `qa-whisper-range-2026-09-07.md`.

Collection audio is an independent mono PCM16 WAV in private application storage, accompanied by a database snapshot of the subtitle, source title and original interval. It does not depend on the original lesson or a loaded model. Identical saves reuse a snapshot; changed bounds/revisions/transcripts create another clip. Serialized mutations, atomic export publication, interrupted-deletion recovery and orphan cleanup protect file/database consistency. Database version 4 adds the table without changing existing lessons, models, vocabulary or conversations.

Study retains Vocabulary and adds Collection. Clips have playback, replay, seek, full selectable subtitles and confirmed deletion. Collection playback stops when leaving the collection, covering its route, backgrounding the application or disposing the screen. Starting a clip pauses Listening playback. Auto OFF continues to hide transcript caches until Transcribe is tapped, so hidden transcripts cannot be saved through this button.

Automatic stopping retains the finished cut selected at its exact endpoint for Replay. Play continues onward, or restarts from the beginning at file end. Tests exercise all four Repeat/Auto-stop combinations, adjacent cuts, gaps, EOF, navigation, late position callbacks, and pause/seek/lesson-switch races. Controls preserve 48 dp touch targets and wrap on narrow screens.

Device testing also exposed two native-callback details. Collection ignores a late zero-position callback after EOF, preserving the final progress position. Listening uses a 40 ms timer instead of Flutter-frame polling, since a system file picker can stop Flutter frames while native audio continues. Only one position query can be in flight, and stale results after seek/pause/lesson changes are discarded.

## Device and release verification

- Pixel 6 signed-upgrade app request for an uncached TED segment at **49.402–56.425 seconds**: **368 ms decode + 1,478 ms inference**, about **1.85 seconds** total native work. The complete result was: “Maybe my father was right and it is all about safety, but not in the way we usually think, and I will show you why.” Its Collection export is **224,780 bytes**, exactly 7.023 seconds of mono PCM16 plus the WAV header.
- An isolated `qa-collection` WAV lesson returned `Hello.`. Its **35,180-byte** standalone clip survived deletion of that lesson, then played to EOF after a hot restart. The progress correctly remained at the end. Deleting this clip removed its row and file; the temporary import/source were removed. Original lessons, model files and three vocabulary entries remained present.
- One TED excerpt was retained in Collection as the demonstrated saved clip. Auto OFF continued to hide cached Listening text on reopen until Transcribe was tapped.

- With Repeat and Auto-stop both enabled, background playback on the Android Home screen completed six consecutive **49.402–56.425-second** loops. Disabling Repeat left Auto-stop active and paused at the segment end. With both disabled, playback continued through subsequent cuts/gaps to 1:13 before a manual pause. Listening was restored to approximately 0:29, Auto-stop on, Repeat off, Auto transcript off, Edit off.
- Collection playback stops on backgrounding; returning shows paused playback at the beginning. The original three lessons and vocabulary entries remained present after signed upgrades. No crash entries belonged to the tested application PIDs; earlier standalone codec-probe failure logs were retained.
- `flutter analyze`: **No issues found**. `flutter test --concurrency=1`: **293 passed**, zero failed (82 seconds). Host filesystem/FFI work is explicitly isolated or awaited in navigation/model-inventory widget tests.
- Final `flutter build apk --release`: success, **70.6 seconds**, after removing temporary debug-signing configuration. Fixed artifact: **`release/app-release.apk`**, **95,291,849 bytes**, SHA-256 **`F4A8CDB6DD2E8F620BD73D5AF6EE5D627859A0A7EA0A85FB210F5A76FE899DCA`**.
- `apksigner verify --verbose --print-certs`: verified, APK Signature Scheme v2 true. Signer SHA-256: **`68:90:D4:8A:B8:F1:B2:60:83:92:FA:D0:F9:DF:FA:D9:D7:7F:12:57:55:4B:17:E2:A8:66:A7:D2:E7:D1:16:DA`**.
- Final signed upgrade succeeded on Pixel 6 via `adb install -r`, preserving Collection and existing data. Final application PID: **23825**. Existing upstream `flutter_tts` Kotlin compatibility notice remains; current build succeeds. Previously policy-blocked duplicate APK cleanup was not retried or bypassed.
