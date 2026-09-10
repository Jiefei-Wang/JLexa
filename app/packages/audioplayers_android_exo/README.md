# JLexa Android ExoPlayer adapter

This is a minimal vendored copy of `audioplayers_android_exo` 0.1.4 from
`%LOCALAPPDATA%/Pub/Cache/hosted/pub.dev/audioplayers_android_exo-0.1.4`
on 2026-09-08. Upstream: https://github.com/bluefireteam/audioplayers/tree/master/packages/audioplayers_android_exo.
The upstream MIT license is retained in `LICENSE`. This Android-only plugin has
no Dart library; Flutter registers its native plugin from `pubspec.yaml`.
The published workspace resolution flag was removed for use as a local path dependency.

The copied cache already contained the project's Android build compatibility
changes: Android compile SDK 36, Java/Kotlin JVM 17, AGP 9 built-in Kotlin style
(no separate Kotlin Android plugin application), Media3 1.9.0 dependencies and
`androidx.media3` imports. Its adaptive channel mixer and mono-volume handling
are preserved. `android/build.gradle` is copied unchanged from that working cache.

## JLexa playback end extension

On the existing `xyz.luan/audioplayers` method channel:

```
setPlaybackEnd({playerId: String, endMs: int?, positionMs: int?}) -> 1
```

- Call only after assigning a source to the player. `endMs` is a positive absolute
  file time in milliseconds; null removes clipping. `positionMs` is nonnegative
  and absolute; null keeps the current native position (or a pending explicit
  seek when preparation has not finished).
- A changed end rebuilds a Media3 `ClippingMediaSource` with start zero and the
  requested end. This clears old decoder buffers and retains native playback
  intent. Rebuilding can briefly buffer. An unchanged end is a no-op, including
  its `positionMs`; use the standard `seek` method to reposition afterward.
- Removing the end restores the full source. Without an end, native looping and
  completion behavior remain upstream behavior. With an end, native looping is
  disabled and completion pauses without seeking to zero or releasing the source,
  then sends standard `audio.onComplete` so Dart owns repeat / auto-stop.
- `getCurrentPosition` stays absolute because clipping always starts at zero.
  `getDuration` observes and caches the original child timeline before clipping;
  it never reports the artificial clip length as the whole-file duration. During
  preparation the existing wrapper can still return null for either getter.
- Assigning a new source, reassigning a clipped source, releasing, or disposing
  clears the previous end and stale pending seek. Normal `stop` still performs
  its upstream reset-to-zero behavior; only clipped completion bypasses it.
- With a source assigned, seeks go directly to ExoPlayer even while preparing;
  Media3 owns pending initial seeks. This avoids waiting forever for READY when
  preparation at EOF goes straight to ENDED. Completion also makes getters
  available if READY was skipped, without starting playback. Any legacy pending
  seek is applied once before start and cleared. Changing an end preserves a
  pending target unless `positionMs` replaces it. A Pause during rebuilding
  clears native playWhenReady before readiness.

Clipping uses Media3's media-period boundary, not Dart's position polling. Exact
heard boundaries still depend on decoder frame handling and must be verified on
real audio; this fork does not claim sample-accurate trimming of every codec.

API references checked against the installed Media3 1.9.0 classes and official docs:
- https://developer.android.com/reference/androidx/media3/exoplayer/source/ClippingMediaSource.Builder
- https://developer.android.com/reference/androidx/media3/exoplayer/source/WrappingMediaSource
