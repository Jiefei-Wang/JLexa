package com.example.local_ai_app

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

object AudioDecoder {

    data class DecodedAudioResult(
        val durationMs: Long,
        val samples16kMono: FloatArray,
        val waveformPeaks: List<Double>
    )

    private class ShortChunkBuffer(private val chunkSize: Int = 32768) {
        private val chunks = mutableListOf<ShortArray>()
        private var currentChunk = ShortArray(chunkSize)
        private var currentPos = 0
        var totalSize = 0
            private set

        fun add(value: Short) {
            if (currentPos >= chunkSize) {
                chunks.add(currentChunk)
                currentChunk = ShortArray(chunkSize)
                currentPos = 0
            }
            currentChunk[currentPos++] = value
            totalSize++
        }

        fun toFlatArray(): ShortArray {
            val result = ShortArray(totalSize)
            var offset = 0
            for (chunk in chunks) {
                System.arraycopy(chunk, 0, result, offset, chunkSize)
                offset += chunkSize
            }
            if (currentPos > 0) {
                System.arraycopy(currentChunk, 0, result, offset, currentPos)
            }
            return result
        }
    }

    /**
     * Decodes an audio file (MP3, M4A, AAC, WAV) to a 16kHz mono float array suitable for Whisper.
     */
    fun decodeTo16kHzMonoPcm(filePath: String): FloatArray {
        val result = decodeAudioFull(filePath, numPeaks = 0)
        return result?.samples16kMono ?: FloatArray(0)
    }

    /**
     * Decodes audio and computes real duration, 16kHz mono PCM, and real waveform peaks.
     */
    fun decodeAudioFull(filePath: String, numPeaks: Int = 200): DecodedAudioResult? {
        val file = File(filePath)
        if (!file.exists() || file.length() < 12) return null

        // Try standard RIFF/WAVE parsing first
        if (filePath.endsWith(".wav", ignoreCase = true)) {
            val wavResult = parseWavFile(file, numPeaks)
            if (wavResult != null) return wavResult
        }

        // MediaCodec fallback for MP3, M4A, AAC, FLAC, OGG, and non-standard WAV
        return decodeWithMediaCodec(file, numPeaks)
    }

    private fun parseWavFile(file: File, numPeaks: Int): DecodedAudioResult? {
        try {
            FileInputStream(file).use { fis ->
                val header = ByteArray(12)
                if (fis.read(header) < 12) return null
                val headerBuf = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)

                val riff = String(header, 0, 4)
                val wave = String(header, 8, 4)
                if (riff != "RIFF" || wave != "WAVE") return null

                var channels = 1
                var sampleRate = 16000
                var bitsPerSample = 16
                var audioFormat = 1
                var dataBytes: ByteArray? = null

                val chunkHeader = ByteArray(8)
                while (fis.read(chunkHeader) == 8) {
                    val chunkBuf = ByteBuffer.wrap(chunkHeader).order(ByteOrder.LITTLE_ENDIAN)
                    val chunkId = String(chunkHeader, 0, 4)
                    val chunkSize = chunkBuf.getInt(4).toLong() and 0xFFFFFFFFL

                    if (chunkId == "fmt ") {
                        val fmtData = ByteArray(chunkSize.toInt())
                        if (fis.read(fmtData) != fmtData.size) return null
                        val fmtBuf = ByteBuffer.wrap(fmtData).order(ByteOrder.LITTLE_ENDIAN)
                        audioFormat = fmtBuf.getShort(0).toInt() and 0xFFFF
                        channels = fmtBuf.getShort(2).toInt() and 0xFFFF
                        sampleRate = fmtBuf.getInt(4)
                        bitsPerSample = fmtBuf.getShort(14).toInt() and 0xFFFF
                    } else if (chunkId == "data") {
                        val toRead = min(chunkSize, file.length() - 44).toInt()
                        dataBytes = ByteArray(toRead)
                        var readSoFar = 0
                        while (readSoFar < toRead) {
                            val r = fis.read(dataBytes, readSoFar, toRead - readSoFar)
                            if (r <= 0) break
                            readSoFar += r
                        }
                        break
                    } else {
                        // Skip unneeded chunks (e.g. LIST, ID3, JUNK) with word alignment
                        val skipBytes = if (chunkSize % 2L != 0L) chunkSize + 1L else chunkSize
                        fis.skip(skipBytes)
                    }
                }

                if (dataBytes == null || channels <= 0 || sampleRate <= 0) return null

                val monoFloats: FloatArray
                if (bitsPerSample == 16 && (audioFormat == 1 || audioFormat == 0xFFFE)) {
                    val totalShorts = dataBytes.size / 2
                    val totalFrames = totalShorts / channels
                    monoFloats = FloatArray(totalFrames)
                    val bb = ByteBuffer.wrap(dataBytes).order(ByteOrder.LITTLE_ENDIAN)
                    val sb = bb.asShortBuffer()
                    for (i in 0 until totalFrames) {
                        var sum = 0.0f
                        for (c in 0 until channels) {
                            if (sb.hasRemaining()) {
                                sum += sb.get().toFloat() / 32768.0f
                            }
                        }
                        monoFloats[i] = sum / channels.toFloat()
                    }
                } else if (bitsPerSample == 8) {
                    val totalFrames = dataBytes.size / channels
                    monoFloats = FloatArray(totalFrames)
                    for (i in 0 until totalFrames) {
                        var sum = 0.0f
                        for (c in 0 until channels) {
                            val byteVal = dataBytes[i * channels + c].toInt() and 0xFF
                            sum += (byteVal - 128) / 128.0f
                        }
                        monoFloats[i] = sum / channels.toFloat()
                    }
                } else if (bitsPerSample == 32 && audioFormat == 3) {
                    val totalFloats = dataBytes.size / 4
                    val totalFrames = totalFloats / channels
                    monoFloats = FloatArray(totalFrames)
                    val fb = ByteBuffer.wrap(dataBytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
                    for (i in 0 until totalFrames) {
                        var sum = 0.0f
                        for (c in 0 until channels) {
                            if (fb.hasRemaining()) {
                                sum += fb.get()
                            }
                        }
                        monoFloats[i] = sum / channels.toFloat()
                    }
                } else {
                    return null // Unsupported bit depth in direct WAV parser -> use MediaCodec
                }

                val resampled16k = resampleTo16kHz(monoFloats, sampleRate)
                val durationMs = (monoFloats.size.toDouble() * 1000.0 / sampleRate.toDouble()).toLong()
                val peaks = computeWaveformPeaks(resampled16k, if (numPeaks > 0) numPeaks else 200)

                return DecodedAudioResult(durationMs, resampled16k, peaks)
            }
        } catch (_: Exception) {
            return null
        }
    }

    private fun decodeWithMediaCodec(file: File, numPeaks: Int): DecodedAudioResult? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(file.absolutePath)
            var audioTrackIndex = -1
            var format: MediaFormat? = null

            for (i in 0 until extractor.trackCount) {
                val trackFormat = extractor.getTrackFormat(i)
                val mime = trackFormat.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("audio/")) {
                    audioTrackIndex = i
                    format = trackFormat
                    break
                }
            }

            if (audioTrackIndex == -1 || format == null) {
                extractor.release()
                return null
            }

            extractor.selectTrack(audioTrackIndex)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
            var sampleRate = if (format.containsKey(MediaFormat.KEY_SAMPLE_RATE)) format.getInteger(MediaFormat.KEY_SAMPLE_RATE) else 44100
            var channelCount = if (format.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) else 2
            val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else 0L

            val codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            val pcmBuffer = ShortChunkBuffer()
            val bufferInfo = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false

            while (!outputDone) {
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(10000)
                    if (inIndex >= 0) {
                        val inputBuffer = codec.getInputBuffer(inIndex)
                        if (inputBuffer != null) {
                            val sampleSize = extractor.readSampleData(inputBuffer, 0)
                            if (sampleSize < 0) {
                                codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                codec.queueInputBuffer(inIndex, 0, sampleSize, extractor.sampleTime, 0)
                                extractor.advance()
                            }
                        }
                    }
                }

                var outIndex = codec.dequeueOutputBuffer(bufferInfo, 10000)
                while (outIndex >= 0) {
                    val outputBuffer = codec.getOutputBuffer(outIndex)
                    if (outputBuffer != null && bufferInfo.size > 0) {
                        outputBuffer.position(bufferInfo.offset)
                        outputBuffer.limit(bufferInfo.offset + bufferInfo.size)
                        val shortBuffer = outputBuffer.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                        while (shortBuffer.hasRemaining()) {
                            pcmBuffer.add(shortBuffer.get())
                        }
                    }
                    codec.releaseOutputBuffer(outIndex, false)

                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        outputDone = true
                        break
                    }
                    outIndex = codec.dequeueOutputBuffer(bufferInfo, 10000)
                }

                if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val newFormat = codec.outputFormat
                    if (newFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                        sampleRate = newFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    }
                    if (newFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                        channelCount = newFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    }
                }
            }

            codec.stop()
            codec.release()
            extractor.release()

            val rawShorts = pcmBuffer.toFlatArray()
            val safeChannels = if (channelCount > 0) channelCount else 1
            val totalFrames = rawShorts.size / safeChannels
            val monoFloats = FloatArray(totalFrames)

            for (i in 0 until totalFrames) {
                var sum = 0.0f
                for (c in 0 until safeChannels) {
                    val idx = i * safeChannels + c
                    if (idx < rawShorts.size) {
                        sum += rawShorts[idx].toFloat() / 32768.0f
                    }
                }
                monoFloats[i] = sum / safeChannels.toFloat()
            }

            val resampled16k = resampleTo16kHz(monoFloats, sampleRate)
            val durationMs = if (durationUs > 0) (durationUs / 1000L) else (monoFloats.size.toDouble() * 1000.0 / sampleRate.toDouble()).toLong()
            val peaks = computeWaveformPeaks(resampled16k, if (numPeaks > 0) numPeaks else 200)

            return DecodedAudioResult(durationMs, resampled16k, peaks)
        } catch (e: Exception) {
            try { extractor.release() } catch (_: Exception) {}
            return null
        }
    }

    private fun resampleTo16kHz(monoFloats: FloatArray, origSampleRate: Int): FloatArray {
        if (monoFloats.isEmpty()) return FloatArray(0)
        if (origSampleRate == 16000) return monoFloats

        val totalFrames = monoFloats.size
        val targetLength = ((totalFrames.toLong() * 16000) / origSampleRate).toInt()
        val resampled = FloatArray(targetLength)
        val ratio = origSampleRate.toDouble() / 16000.0

        for (i in 0 until targetLength) {
            val srcIdx = i * ratio
            val index0 = srcIdx.toInt().coerceIn(0, totalFrames - 1)
            val index1 = (index0 + 1).coerceIn(0, totalFrames - 1)
            val frac = (srcIdx - index0).toFloat()
            resampled[i] = monoFloats[index0] * (1.0f - frac) + monoFloats[index1] * frac
        }

        return resampled
    }

    private fun computeWaveformPeaks(samples16k: FloatArray, targetPoints: Int): List<Double> {
        if (samples16k.isEmpty()) return emptyList()
        val points = max(50, targetPoints)
        val blockSize = max(1, samples16k.size / points)
        val peaks = mutableListOf<Double>()

        var i = 0
        while (i < samples16k.size) {
            var maxAmp = 0.0f
            val end = min(i + blockSize, samples16k.size)
            for (j in i until end step 2) {
                val amp = abs(samples16k[j])
                if (amp > maxAmp) maxAmp = amp
            }
            peaks.add(maxAmp.toDouble().coerceIn(0.02, 1.0))
            i += blockSize
        }
        return peaks
    }
}
