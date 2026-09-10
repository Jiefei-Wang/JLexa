package xyz.luan.audioplayers.player

import android.content.Context
import android.media.AudioManager
import xyz.luan.audioplayers.AudioContextAndroid
import xyz.luan.audioplayers.AudioplayersPlugin
import xyz.luan.audioplayers.EventHandler
import xyz.luan.audioplayers.ReleaseMode
import xyz.luan.audioplayers.source.Source
import kotlin.math.min

class WrappedPlayer internal constructor(
    private val ref: AudioplayersPlugin,
    val eventHandler: EventHandler,
    var context: AudioContextAndroid,
) {
    private var player: PlayerWrapper? = null

    init {
        createPlayer().also {
            player = it
        }
    }
    var source: Source? = null
        set(value) {
            if (field != value || player?.playbackEndMs != null) {
                field = value
                prepared = false
                shouldSeekTo = -1
                if (value != null) {
                    released = false
                    player?.setSource(value)
                    player?.configAndPrepare()
                } else {
                    released = true
                    playing = false
                    player?.release()
                }
            } else {
                ref.handlePrepared(this, true)
            }
        }

    var volume = 1.0f
        set(value) {
            if (field != value) {
                field = value
                if (!released) {
                    player?.setVolumeAndBalance(value, balance)
                }
            }
        }

    var balance = 0.0f
        set(value) {
            if (field != value) {
                field = value
                if (!released) {
                    player?.setVolumeAndBalance(volume, value)
                }
            }
        }

    var rate = 1.0f
        set(value) {
            if (field != value) {
                field = value
                if (playing) {
                    player?.setRate(value)
                }
            }
        }

    var releaseMode = ReleaseMode.RELEASE
        set(value) {
            if (field != value) {
                field = value
                if (!released) {
                    player?.setLooping(isLooping)
                }
            }
        }

    val isLooping: Boolean
        get() = releaseMode == ReleaseMode.LOOP

    var released = true

    var prepared: Boolean = false
        set(value) {
            if (field != value) {
                field = value
                ref.handlePrepared(this, value)
            }
        }

    var playing = false
    var shouldSeekTo = -1

    private val focusManager = FocusManager.create(
        this,
        onGranted = {
            // Check if in playing state, as the focus can also be gained e.g. after a phone call, even if not playing.
            if (playing) {
                player?.start()
            }
        },
        onLoss = { isTransient ->
            if (isTransient) {
                // Do not check or set playing state, as the state should be recovered after granting focus again.
                player?.pause()
            } else {
                // Audio focus won't be recovered
                pause()
            }
        },
    )

    fun updateAudioContext(audioContext: AudioContextAndroid) {
        if (context == audioContext) {
            return
        }
        if (context.audioFocus != AudioManager.AUDIOFOCUS_NONE &&
            audioContext.audioFocus == AudioManager.AUDIOFOCUS_NONE
        ) {
            focusManager.handleStop()
        }
        this.context = audioContext.copy()

        // AudioManager values are set globally
        audioManager.mode = context.audioMode
        audioManager.isSpeakerphoneOn = context.isSpeakerphoneOn

        player?.let { p ->
            p.stop()
            prepared = false
            // Context is only applied, once the player.reset() was called
            p.updateContext(context)
            source?.let {
                p.setSource(it)
                p.configAndPrepare()
            }
        }
    }

    // Getters

    /**
     * Returns the duration of the media in milliseconds, if available.
     */
    fun getDuration(): Int? {
        return if (prepared) player?.getDuration() else null
    }

    /**
     * Returns the current position of the playback in milliseconds, if available.
     */
    fun getCurrentPosition(): Int? {
        return if (prepared) player?.getCurrentPosition() else null
    }

    val applicationContext: Context
        get() = ref.getApplicationContext()

    val audioManager: AudioManager
        get() = ref.getAudioManager()

    /**
     * Playback handling methods
     */
    fun resume() {
        if (!playing && !released) {
            playing = true
            if (prepared) {
                requestFocusAndStart()
            }
        }
    }

    // Try to get audio focus and then start.
    private fun requestFocusAndStart() {
        focusManager.maybeRequestAudioFocus()
    }

    fun stop() {
        focusManager.handleStop()
        if (released) {
            return
        }
        if (releaseMode != ReleaseMode.RELEASE) {
            pause()
            if (prepared) {
                player?.stop()
            }
        } else {
            release()
        }
    }

    fun release() {
        focusManager.handleStop()
        if (released) {
            return
        }
        if (playing) {
            player?.stop()
        }

        // Setting source to null will reset released, prepared and playing
        // and also calls player.release()
        source = null
    }

    fun pause() {
        if (playing) {
            playing = false
            // A clip rebuild may still be preparing with playWhenReady=true.
            // Pause must cancel native intent even before STATE_READY arrives.
            player?.pause()
        }
    }

    fun setPlaybackEnd(endMs: Int?, positionMs: Int?) {
        val current = player ?: error("Player has been disposed")
        check(source != null && !released) { "Set a source before setting its playback end" }
        if (current.playbackEndMs == endMs) return
        // Native rebuilding installs the requested absolute position. A later
        // Dart seek may replace it while preparing and is applied before start.
        val position = positionMs ?: shouldSeekTo.takeIf { it >= 0 }
        prepared = false
        shouldSeekTo = -1
        current.setPlaybackEnd(endMs, position)
    }

    // ExoPlayer owns pending seeks while its timeline is preparing. Waiting
    // for READY here deadlocks when a clipped source goes straight to ENDED.
    fun seek(position: Int) {
        shouldSeekTo = if (source != null && !released) {
            player?.seekTo(position)
            -1
        } else {
            position
        }
    }

    /**
     * Player callbacks
     */
    fun onPrepared() {
        prepared = true
        ref.handleDuration(this)
        if (shouldSeekTo >= 0) {
            val pendingPosition = shouldSeekTo
            shouldSeekTo = -1
            player?.seekTo(pendingPosition)
        }
        if (playing) {
            requestFocusAndStart()
        }
    }

    fun onCompletion() {
        if (!released && !prepared) {
            // Preparing at EOF may produce ENDED without a preceding READY.
            // Make position and full duration available without starting audio.
            prepared = true
            ref.handleDuration(this)
        }
        if (player?.playbackEndMs != null) {
            // Keep the clipped end selected. Dart owns repeat / auto-stop and
            // must not observe the upstream stop() seek back to zero here.
            playing = false
            player?.pause()
            ref.handleComplete(this)
            return
        }
        if (releaseMode != ReleaseMode.LOOP) {
            stop()
        }
        ref.handleComplete(this)
    }

    @Suppress("UNUSED_PARAMETER")
    fun onBuffering(percent: Int) {
        // TODO(luan): expose this as a stream
    }

    fun onSeekComplete() {
        ref.handleSeekComplete(this)
    }

    fun handleLog(message: String) {
        ref.handleLog(this, message)
    }

    fun handleError(errorCode: String?, errorMessage: String?, errorDetails: Any?) {
        ref.handleError(this, errorCode, errorMessage, errorDetails)
    }

    /**
     * Internal logic. Private methods
     */

    /**
     * Create new player
     */
    private fun createPlayer(): PlayerWrapper {
        return ExoPlayerWrapper(this, ref.getApplicationContext())
    }

    private fun PlayerWrapper.configAndPrepare() {
        setVolumeAndBalance(volume, balance)
        setLooping(isLooping)
        prepare()
    }

    private fun PlayerWrapper.setVolumeAndBalance(volume: Float, balance: Float) {
        val leftVolume = min(1f, 1f - balance) * volume
        val rightVolume = min(1f, 1f + balance) * volume
        setVolume(leftVolume, rightVolume)
    }

    fun dispose() {
        release()
        player?.dispose()
        player = null
        eventHandler.dispose()
    }
}
