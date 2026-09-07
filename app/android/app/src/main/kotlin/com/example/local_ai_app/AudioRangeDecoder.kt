package com.example.local_ai_app

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.SystemClock
import android.util.Log
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CancellationException
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.roundToLong

/** Decodes only a requested interval. Codec timestamps remain on the source timeline. */
object AudioRangeDecoder {
    private const val PREROLL_US = 500_000L

    fun decode(filePath: String, startMs: Long, endMs: Long, cancelled: (() -> Boolean)? = null): AudioDecoder.DecodedPcmBuffer {
        require(startMs >= 0 && endMs > startMs) { "Audio range must have 0 <= startMs < endMs" }
        require(endMs <= Int.MAX_VALUE && endMs - startMs <= Int.MAX_VALUE / 16) { "Audio range is too long" }
        val file = File(filePath)
        require(file.isFile) { "Audio source does not exist" }
        checkCancellation(cancelled)
        val started = SystemClock.elapsedRealtime()
        val pcm = decodeWav(file, startMs, endMs, cancelled)
            ?: decodeCompressed(file, startMs, endMs, cancelled)
        checkCancellation(cancelled)
        Log.i("JLexaAudio", "range_decode start_ms=$startMs end_ms=$endMs samples=${pcm.validSampleCount} elapsed_ms=${SystemClock.elapsedRealtime() - started}")
        return pcm
    }

    private fun checkCancellation(cancelled: (() -> Boolean)?) {
        if (cancelled?.invoke() == true) throw CancellationException("Audio decoding cancelled")
    }

    /** Output positions are anchored to the requested absolute 16 kHz sample grid. */
    internal class Collector(private val startMs: Long, endMs: Long, private val rate: Int) {
        private val limit = ((endMs - startMs) * 16).toInt()
        private var samples = FloatArray(minOf(limit, 16000 * 30))
        var count = 0
            private set
        val complete get() = count == limit
        private var previousFrame = Long.MIN_VALUE
        private var previousSample = 0f

        private fun sourcePosition() = (startMs * 16.0 + count) * rate / 16000.0

        private fun append(value: Float) {
            if (count == samples.size) samples = samples.copyOf(minOf(limit, maxOf(count + 16000, count + count / 2)))
            samples[count++] = if (value.isFinite()) value.coerceIn(-1f, 1f) else 0f
        }

        fun feed(mono: FloatArray, frames: Int, firstFrame: Long) {
            if (frames == 0 || complete) return
            while (!complete) {
                val position = sourcePosition()
                val lower = floor(position + 1e-8).toLong()
                val fraction = (position - lower).coerceIn(0.0, 1.0).toFloat()
                val index = lower - firstFrame
                if (index >= frames || (index == frames - 1L && fraction > 1e-6f)) break
                val a = when {
                    index >= 0 -> mono[index.toInt()]
                    lower == previousFrame -> previousSample
                    // Pre-roll should contain the first requested sample. Never silently shift a clip.
                    else -> throw IllegalStateException("Decoder skipped the requested audio start")
                }
                val b = if (fraction <= 1e-6f) a else mono[(index + 1).toInt()]
                append(a + (b - a) * fraction)
            }
            previousFrame = firstFrame + frames - 1
            previousSample = mono[frames - 1]
        }

        fun finish(): AudioDecoder.DecodedPcmBuffer {
            // The last input sample represents its full sample interval, including at EOF.
            while (!complete && sourcePosition() < previousFrame + 1.0) append(previousSample)
            return AudioDecoder.DecodedPcmBuffer(samples.copyOf(count), count)
        }
    }

    private fun decodeWav(file: File, startMs: Long, endMs: Long, cancelled: (() -> Boolean)?): AudioDecoder.DecodedPcmBuffer? {
        RandomAccessFile(file, "r").use { input ->
            if (input.length() < 12) return null
            val header = ByteArray(12).also(input::readFully)
            if (String(header, 0, 4, Charsets.US_ASCII) != "RIFF" || String(header, 8, 4, Charsets.US_ASCII) != "WAVE") return null
            var channels = 0
            var rate = 0
            var bits = 0
            var encoding = 0
            var dataStart = 0L
            var dataSize = 0L
            while (input.filePointer + 8 <= input.length()) {
                checkCancellation(cancelled)
                val chunk = ByteArray(8).also(input::readFully)
                val size = ByteBuffer.wrap(chunk).order(ByteOrder.LITTLE_ENDIAN).getInt(4).toLong() and 0xffffffffL
                val next = input.filePointer + size + (size and 1)
                when (String(chunk, 0, 4, Charsets.US_ASCII)) {
                    "fmt " -> {
                        if (size < 16 || size > 65536 || next > input.length()) return null
                        val fmt = ByteBuffer.wrap(ByteArray(size.toInt()).also(input::readFully)).order(ByteOrder.LITTLE_ENDIAN)
                        encoding = fmt.getShort(0).toInt() and 0xffff
                        channels = fmt.getShort(2).toInt() and 0xffff
                        rate = fmt.getInt(4)
                        bits = fmt.getShort(14).toInt() and 0xffff
                        if (encoding == 0xfffe && size >= 40) encoding = fmt.getShort(24).toInt() and 0xffff
                    }
                    "data" -> {
                        dataStart = input.filePointer
                        dataSize = minOf(size, input.length() - dataStart)
                    }
                }
                if (dataStart > 0 && channels > 0) break
                if (next > input.length()) return null
                input.seek(next)
            }
            if (rate <= 0 || channels !in 1..32 || dataStart == 0L ||
                !((encoding == 1 && bits in listOf(8, 16, 24, 32)) || (encoding == 3 && bits == 32))) return null
            val frameBytes = channels * (bits / 8)
            val totalFrames = dataSize / frameBytes
            var frame = maxOf(0, startMs * rate / 1000 - 1)
            val lastFrame = minOf(totalFrames, ceil(endMs.toDouble() * rate / 1000).toLong() + 1)
            val collector = Collector(startMs, endMs, rate)
            if (frame >= totalFrames) return collector.finish()
            input.seek(dataStart + frame * frameBytes)
            val bytes = ByteArray(4096 * frameBytes)
            val mono = FloatArray(4096)
            while (frame < lastFrame && !collector.complete) {
                checkCancellation(cancelled)
                val frames = minOf(4096L, lastFrame - frame).toInt()
                input.readFully(bytes, 0, frames * frameBytes)
                val buffer = ByteBuffer.wrap(bytes, 0, frames * frameBytes).order(ByteOrder.LITTLE_ENDIAN)
                for (i in 0 until frames) {
                    var value = 0f
                    repeat(channels) {
                        value += when (bits) {
                            8 -> ((buffer.get().toInt() and 0xff) - 128) / 128f
                            16 -> buffer.short / 32768f
                            24 -> {
                                val packed = (buffer.get().toInt() and 0xff) or ((buffer.get().toInt() and 0xff) shl 8) or (buffer.get().toInt() shl 16)
                                packed / 8388608f
                            }
                            else -> if (encoding == 3) buffer.float else (buffer.int / 2147483648.0).toFloat()
                        }
                    }
                    mono[i] = value / channels
                }
                collector.feed(mono, frames, frame)
                frame += frames
            }
            return collector.finish()
        }
    }

    private fun decodeCompressed(file: File, startMs: Long, endMs: Long, cancelled: (() -> Boolean)?): AudioDecoder.DecodedPcmBuffer {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(file.absolutePath)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: throw IllegalArgumentException("Source has no audio track")
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val startUs = startMs * 1000
            val endUs = endMs * 1000
            val seekUs = maxOf(0, startUs - PREROLL_US)
            codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            codec.configure(format, null, null, 0)
            codec.start()
            var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var encoding = AudioFormat.ENCODING_PCM_16BIT
            var collector: Collector? = null
            var inputDone = false
            var outputDone = false
            var prefixFrames = 0L
            var presentationOffsetFrames = 0L
            var jumped = false
            var lastProgress = SystemClock.elapsedRealtime()
            val info = MediaCodec.BufferInfo()
            while (!outputDone && collector?.complete != true) {
                checkCancellation(cancelled)
                var progressed = false
                if (!inputDone) {
                    val index = codec.dequeueInputBuffer(0)
                    if (index >= 0) {
                        val buffer = codec.getInputBuffer(index) ?: error("Missing decoder input buffer")
                        val pts = extractor.sampleTime
                        // AAC encoder priming may legitimately have a negative timestamp.
                        // Only a negative read size means extractor EOF.
                        val size = if (pts > endUs + PREROLL_US) -1 else extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(index, 0, 0, maxOf(0, pts), MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(index, 0, size, pts, 0)
                            extractor.advance()
                        }
                        progressed = true
                    }
                }
                val index = codec.dequeueOutputBuffer(info, if (progressed) 0 else 1000)
                when {
                    index >= 0 -> {
                        var mayJump = false
                        try {
                            if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                                require(rate > 0 && channels in 1..32) { "Invalid decoder PCM format" }
                                val buffer = codec.getOutputBuffer(index) ?: error("Missing decoder output buffer")
                                buffer.position(info.offset)
                                buffer.limit(info.offset + info.size)
                                buffer.order(ByteOrder.LITTLE_ENDIAN)
                                val bytesPerSample = when (encoding) {
                                    AudioFormat.ENCODING_PCM_FLOAT -> 4
                                    AudioFormat.ENCODING_PCM_16BIT -> 2
                                    else -> error("Unsupported decoder PCM encoding: $encoding")
                                }
                                val frames = info.size / (channels * bytesPerSample)
                                val mono = FloatArray(frames)
                                for (i in 0 until frames) {
                                    var value = 0f
                                    repeat(channels) { value += if (bytesPerSample == 4) buffer.float else buffer.short / 32768f }
                                    mono[i] = value / channels
                                }
                                val ptsFrame = (info.presentationTimeUs.toDouble() * rate / 1_000_000).roundToLong()
                                val firstFrame = if (jumped) ptsFrame - presentationOffsetFrames else prefixFrames
                                if (!jumped) {
                                    // Gapless trimming does not consistently advance the first
                                    // BufferInfo timestamp. Calibrate from continuous PCM after
                                    // the initial trimmed buffer, before seeking.
                                    presentationOffsetFrames = ptsFrame - prefixFrames
                                    prefixFrames += frames
                                    mayJump = prefixFrames >= rate / 10 && seekUs > extractor.sampleTime + 50_000 && !inputDone
                                }
                                val activeCollector = collector ?: Collector(startMs, endMs, rate).also { collector = it }
                                activeCollector.feed(mono, frames, firstFrame)
                            }
                            outputDone = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        } finally {
                            codec.releaseOutputBuffer(index, false)
                        }
                        if (mayJump) {
                            codec.flush()
                            if (format.getString(MediaFormat.KEY_MIME) == "audio/mpeg") {
                                // MP3 seekTo can estimate the wrong byte position. Scan
                                // compressed packets only; decoding starts at the preroll.
                                while (extractor.sampleTime in 0 until seekUs) {
                                    checkCancellation(cancelled)
                                    if (!extractor.advance()) break
                                }
                            } else {
                                extractor.seekTo(seekUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                            }
                            jumped = true
                            outputDone = false
                        }
                        progressed = true
                    }
                    index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val output = codec.outputFormat
                        val newRate = output.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        require(collector == null || newRate == rate) { "Sample rate changed within audio range" }
                        rate = newRate
                        channels = output.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        encoding = if (output.containsKey(MediaFormat.KEY_PCM_ENCODING)) output.getInteger(MediaFormat.KEY_PCM_ENCODING) else AudioFormat.ENCODING_PCM_16BIT
                        progressed = true
                    }
                }
                if (progressed) lastProgress = SystemClock.elapsedRealtime()
                check(SystemClock.elapsedRealtime() - lastProgress < 10_000) { "Audio decoder stalled" }
            }
            return collector?.finish() ?: AudioDecoder.DecodedPcmBuffer(FloatArray(0), 0)
        } finally {
            try { codec?.stop() } catch (_: Exception) {}
            try { codec?.release() } catch (_: Exception) {}
            extractor.release()
        }
    }
}
