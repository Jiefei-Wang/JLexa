# Whisper-assisted window segmentation — Pixel 6 QA (2026-09-08)

Settings → Whisper Backend now contains **Whisper-assisted segmentation**, off by default. Auto in Listening only controls cached transcript visibility; it does not start or cancel recognition. Transcribe still explicitly reveals cached text or recognizes a manually edited cut.

The repeater first prepares acoustic speech regions, then groups them into approximately one-minute scheduling windows. Boundaries move to acoustic region edges rather than cutting uninterrupted speech to a fixed duration. Each request includes 15 seconds of context on either side. The currently visited unfinished window is prioritized; a seek can cancel an obsolete background request, but its native terminal completion is awaited before reuse.

Pending windows hide cuts and disable editing/add/delete. A spinner appears beside Local Window. Playback and seeking remain available. Completed windows restore normal controls while remaining windows run serially in the background. Missing models and failures show a concise error/Retry and expose the acoustic fallback, rather than leaving an indefinite spinner.

Recognized tokens are grouped by sentence punctuation and meaningful pauses, retaining absolute timestamps. Whole sentences crossing scheduling boundaries are retained; overlap reconciliation suppresses duplicates and protects finalized cuts, manual edits, and deleted holes in completed windows. Context is expanded for edge fragments. If additional context still cannot resolve an edge, original acoustic bounds are retained without fabricating a transcript. Overlapping native timestamps are merged conservatively rather than losing words.

Window completion and the resulting cut set commit together in a revision-checked SQLite transaction. Per-lesson window state uses app_settings alongside the existing audio_segments transcript cache. Restarts resume unfinished windows; a ready window does not require inference to display cached cuts/text. Redo segments explicitly rebuilds the plan. Reset transcripts clears text while preserving geometry.

## Verification

- Flutter static analysis: no issues; `flutter test --concurrency=1`: **396 passed, 0 failed**.
- Unit/widget coverage includes window planning, punctuation/timestamps, cross-boundary recognition in either completion order, protected manual boundaries/deletions, atomic rollback, current-window priority, cancellation terminal ownership, rapid OFF/ON, restart restoration, Auto visibility, missing-model retry, disabled controls, and initial waveform preparation.
- Physical device: Pixel 6, Android 16, serial 25311FDF6004PR. No Honor operations were performed for this request.
- Real model: Whisper Tiny English through the saved SAF URI; built-in CPU backend, four threads.
- Audio: existing ted-career-safety lesson, 16:45 (1,005.192 s player duration).
- Debug and release upgrades preserved existing models, dictionaries, lessons, and settings. Debug playback/seek remained usable while pending; no debug inference timings are presented as release performance.

## Limits

Whisper punctuation and word timestamps are estimates, so automatic cuts can still require manual correction. Background progress runs while the app process is alive; completed work survives termination. Uninterrupted speech can make a scheduling window longer than one minute. This change improves first-window availability and reuse; it does not imply a fixed recognition latency on every phone/model.

## Release device results

| Scheduling window | PCM decoding | Whisper inference | Ready including save |
|---|---:|---:|---:|
| 00:00–01:00 (final APK) | 2.28 s | 7.07 s | 9.55 s |
| 08:57.105–09:55.378 (first selected window) | 2.90 s | 8.53 s | 11.54 s |
| 07:57.682–08:57.105 (background) | 4.97 s | 10.05 s | 15.10 s |

These measurements include the extra context audio; model startup precedes the request. Later MP3 ranges still incur compressed-prefix scanning overhead. They are observations for this device/model, not a fixed latency promise.

- Auto OFF kept text hidden while recognition completed. Transcribe revealed the cached sentence immediately without starting a selected-cut inference request. Auto ON followed the next cached cut; final preference was restored to Auto OFF.
- After force-stop/relaunch, the 09:18 cut and its transcript restored from cache; only an unfinished background window started. Final signed upgrade also preserved these completed windows.
- Real cross-boundary sentence: **57,000–61,000 ms**, “Do you have to juggle in your daily life too?” The later window completed first, the earlier window then completed without splitting or duplicating this sentence at 60,000 ms. Previous/Next traversed it once. Adjacent cuts were 49,310–57,000 and 61,000–85,000 ms.
- Edit mode could be entered/exited after completion. During pending work the three editing buttons were disabled. Playback and jumping to another unfinished window remained functional.
- Background processing ultimately completed all 18 planned windows (including the short final window), producing 229 persisted cuts. Interrupted windows resumed; no whole-file wall time is inferred from this interrupted QA run.
- Final process PID **28673** remained alive; Android crash buffer had no entries since this release test started. Older crash-buffer entries from unrelated earlier sessions were not treated as new failures.

Screenshots: [pending](images/whisper-window-pixel-release-pending-2026-09-08.png), [ready with explicitly revealed cache](images/whisper-window-pixel-ready-2026-09-08.png), [whole sentence crossing 01:00](images/whisper-window-pixel-cross-boundary-2026-09-08.png).

## Signed artifact

- Fixed path: `release/app-release.apk`, **114,556,211 bytes**.
- SHA-256: `562B5EF9200F774D1A77F0E014CFA3084A06FC2F9E9BEEA84FE1BA3DF3588CF1`.
- Signer SHA-256: `68:90:D4:8A:B8:F1:B2:60:83:92:FA:D0:F9:DF:FA:D9:D7:7F:12:57:55:4B:17:E2:A8:66:A7:D2:E7:D1:16:DA`.
- APK v2 signature verified; installed on Pixel with data preserved. Temporary debug signing was removed before release; the Gradle configuration matches its previous version.
- Generated duplicate debug/release APKs under `app/build/app/outputs/` were removed after verification and copying. The fixed release artifact remains.
