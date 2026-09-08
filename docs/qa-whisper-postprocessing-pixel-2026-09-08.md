# Whisper cut postprocessing — 2026-09-08

## Behavior

After Whisper sentence refinement:

1. Adjacent automatic cuts with a nonnegative gap strictly below 500 ms share
   one boundary at the lowest measured energy. Search the intersection of the
   two original edges' ±250 ms intervals, retaining nonempty cuts. This includes
   touching cuts. Equal-energy points prefer the old edges' midpoint.
2. A resulting cut strictly shorter than 1,500 ms merges with its shorter
   available adjacent cut (left on a tie). The merged span includes any gap and
   must be at most 10,000 ms. If the preferred merge exceeds this limit, leave
   the short cut intact. Repeat for newly formed short cuts. There is no second
   boundary-snap pass after merging.

Energy is unscaled mean-square PCM in 10 ms bins. Bin centers are searched;
an intersection narrower than a bin still receives a valid point within both
250 ms limits. This is an energy minimum at 10 ms analysis resolution, not a
claim of linguistic or sample-level forced alignment.

The native bridge reuses the small envelope from the current Whisper window's
already decoded PCM. Migrating an existing saved window only decodes its audio
range; it does not rerun Whisper and does not require a loaded speech model.
The native plugin ABI is unchanged.

## Persistence and ownership

Window metadata records postprocessing completion and adjusted adjacency IDs in
the same SQLite transaction as the cut list. Cache reopening does not repeatedly
move a shared boundary. A merged cut inherits the already adjusted exterior
boundary even when the retained left ID changes its adjacency key.

Adjacent completed windows can share refined boundaries. Short cuts at a pending
window edge wait for its final neighbor before choosing a merge side. The current
window stays prioritized; pause, navigation and failed transactions reject stale
results. Transcript text is concatenated in time order on merge; existing absolute
token times are retained, and cut/transcript revisions advance together.

Manual cuts are excluded. New manual deletions atomically mark both surviving
neighbors as edited, retaining their bounds, text and tokens so later
postprocessing cannot refill or merge across that intentional gap. Historical
deletions without stored provenance cannot be distinguished from natural gaps;
this does not reconstruct deleted-range history for previously unrecognized
windows.

## Automated checks

* `flutter analyze`: no issues, zero errors/warnings.
* `flutter test --concurrency=1`: **422 passed**, zero failed (75 seconds).
* 18 pure postprocessor cases cover threshold edges, 499 ms narrow intervals,
  touching cuts, nonempty bounds, absolute energy offsets, energy ties,
  neighbor selection, 10-second spans, chain merges, revisions, tokens and
  scoped operations.
* Five real SQLite window-session cases cover legacy-cache migration without a
  model, restart idempotence, cancelled/stale energy, reversed window completion,
  shared boundaries and deferred short-cut merging.
* A controller regression forces a SQLite insertion failure to prove deletion
  and neighbor protection roll back together, then verifies successful deletion
  and persisted transcript protection across reopening.
* `native/tests/AudioEnergyProbe.kt`: independent host JVM probe passed for mean
  square values, silence, partial EOF bins, valid sample counts, offsets, invalid
  inputs, cache coverage and closing during pending work.

## Pixel validation

Device: Pixel 6 `25311FDF6004PR`, Android 16. No Honor testing.

* Existing `ted-career-safety`: all 17 cached windows migrated using audio
  energy without rerunning Whisper. The first window completed in 1,717 ms;
  background migration completed in about 85 seconds. The cut count changed
  from 229 to 203.
* The old 49.000/49.310-second edges now share **49.235 seconds**. Independent
  PCM analysis found the minimum 10 ms energy bin centered there within the
  allowed 49.060–49.250-second interval. The two movements are +235/−75 ms.
* The shared minute-window boundary became 60.975 seconds and remained stable
  when the next window completed. Restart did not start another polish pass.
* Real recorded playback for the new 41.905–49.235-second cut aligned with
  source audio at 41.934–49.325 seconds. Continuous correlation had a minimum
  of 0.945 across 74 blocks. Existing approximately 0.1-second playback stop
  latency remains; this is not sample-accurate output clipping.
* The short sentence “But I made it.” merged with the shorter preceding cut.
  The resulting 30.185–34.135-second cut retained both sentences in its cached
  transcript.
* A fresh 16-second WAV imported through Android's file picker completed real
  Whisper recognition and postprocessing in **1,615 ms**. Logs contain exactly
  one PCM decode (14 ms); postprocessing reused the recognition envelope.
  Three final cuts had shared edges at 4.735 and 9.135 seconds, and merged
  transcript text remained available.
* Deleting that temporary lesson's middle cut preserved the gap after a force
  stop/restart. The temporary lesson and external WAV were then removed.
  Original lessons, audio and models remain intact.
* Final process PID 4873; no new crash-buffer entries since installation.
  Whisper segmentation ON, Auto transcript OFF, Repeat OFF, Auto-stop ON.

## Signed release

* `flutter build apk --release`: succeeded in 103.2 seconds with
  `app/android/key.properties`.
* Fixed artifact: `release/app-release.apk`, **115,686,715 bytes**.
* APK SHA-256:
  `D190A08C1EE93F8E109BB3EC730C3A51F0CDB73FC8BDF6A7FB2217556754A516`.
* Signer SHA-256:
  `68:90:D4:8A:B8:F1:B2:60:83:92:FA:D0:F9:DF:FA:D9:D7:7F:12:57:55:4B:17:E2:A8:66:A7:D2:E7:D1:16:DA`.
* `apksigner verify --verbose --print-certs`: verified, v2 true.
  Installed Pixel `base.apk` SHA-256 matches the fixed release artifact.
* Existing flutter_tts future Kotlin-plugin compatibility and SDK XML tool
  version warnings do not prevent the release build.
* Prior automatic approval review rejected duplicate build-output APK cleanup
  with `blocked by policy`; those two copies remain. Pre-existing untracked
  `artifacts/` was left untouched.
