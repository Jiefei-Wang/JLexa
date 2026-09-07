package com.example.local_ai_app

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

object AudioDecoder {

    data class DecodedPcmBuffer(
        val samples: FloatArray,
        val validSampleCount: Int
    )

    data class DecodedAudioResult(
        val durationMs: Long,
        val pcm: DecodedPcmBuffer,
        val waveformPeaks: List<Double>
    )

    data class WaveformResult(
        val durationMs: Long,
        val waveformPeaks: List<Double>
    )

    class DirectStreamingResampler16k(
        private var sourceSampleRate: Int,
        estimatedOutputSamples: Int = 16000
    ) {
        private var buffer = FloatArray(max(16000, estimatedOutputSamples))
        var count = 0
            private set

        private var hasPrev = false
        private var prevSample = 0.0f
        private var srcPos = 0.0
        private var srcOffset = 0L

        fun updateSourceSampleRate(newRate: Int) {
            if (newRate > 0 && newRate != sourceSampleRate) {
                sourceSampleRate = newRate
            }
        }

        private fun ensureCapacity(needed: Int) {
            if (needed > buffer.size) {
                var newCap = buffer.size + (buffer.size shr 1)
                if (newCap < needed) newCap = needed + 16000
                buffer = buffer.copyOf(newCap)
            }
        }

        private fun addSample(value: Float) {
            if (count >= buffer.size) {
                ensureCapacity(count + 16000)
            }
            buffer[count++] = value
        }

        fun feed(samples: FloatArray, sampleCount: Int) {
            if (sampleCount <= 0) return
            if (sourceSampleRate == 16000) {
                ensureCapacity(count + sampleCount)
                System.arraycopy(samples, 0, buffer, count, sampleCount)
                count += sampleCount
                return
            }

            val ratio = sourceSampleRate.toDouble() / 16000.0
            while (srcPos < srcOffset + sampleCount) {
                val localPos = srcPos - srcOffset
                val idx0 = localPos.toInt()
                val frac = (localPos - idx0).toFloat()
                val s0 = if (idx0 >= 0) samples[idx0] else if (hasPrev) prevSample else samples[0]
                val s1 = if (idx0 + 1 < sampleCount) samples[idx0 + 1] else samples[sampleCount - 1]
                val interpolated = s0 * (1.0f - frac) + s1 * frac
                addSample(interpolated)
                srcPos += ratio
            }

            prevSample = samples[sampleCount - 1]
            hasPrev = true
            srcOffset += sampleCount
        }

        fun finish(): DecodedPcmBuffer {
            return DecodedPcmBuffer(buffer, count)
        }
    }

    /**
     * Cheap metadata-only duration path without full audio decoding.
     */
    fun getAudioMetadata(filePath: String): Long? {
        val file = File(filePath)
        if (!file.exists() || file.length() < 12) return null

        // 1. Fast WAV header inspection
        if (filePath.endsWith(".wav", ignoreCase = true)) {
            try {
                FileInputStream(file).use { fis ->
                    val header = ByteArray(12)
                    if (fis.read(header) == 12) {
                        val riff = String(header, 0, 4)
                        val wave = String(header, 8, 4)
                        if (riff == "RIFF" && wave == "WAVE") {
                            var channels = 1
                            var sampleRate = 16000
                            var bitsPerSample = 16
                            var dataLength = 0L
                            val chunkHeader = ByteArray(8)
                            while (fis.read(chunkHeader) == 8) {
                                val chunkBuf = ByteBuffer.wrap(chunkHeader).order(ByteOrder.LITTLE_ENDIAN)
                                val chunkId = String(chunkHeader, 0, 4)
                                val chunkSize = chunkBuf.getInt(4).toLong() and 0xFFFFFFFFL
                                if (chunkId == "fmt ") {
                                    val fmtData = ByteArray(chunkSize.toInt())
                                    if (fis.read(fmtData) == fmtData.size) {
                                        val fmtBuf = ByteBuffer.wrap(fmtData).order(ByteOrder.LITTLE_ENDIAN)
                                        channels = fmtBuf.getShort(2).toInt() and 0xFFFF
                                        sampleRate = fmtBuf.getInt(4)
                                        bitsPerSample = fmtBuf.getShort(14).toInt() and 0xFFFF
                                    }
                                    if (chunkSize % 2L != 0L) {
                                        fis.skip(1)
                                    }
                                } else if (chunkId == "data") {
                                    dataLength = chunkSize
                                    break
                                } else {
                                    val skipBytes = if (chunkSize % 2L != 0L) chunkSize + 1L else chunkSize
                                    var skipped = 0L
                                    while (skipped < skipBytes) {
                                        val s = fis.skip(skipBytes - skipped)
                                        if (s <= 0) break
                                        skipped += s
                                    }
                                }
                            }
                            val bytesPerFrame = channels * (bitsPerSample / 8)
                            if (bytesPerFrame > 0 && sampleRate > 0 && dataLength > 0) {
                                val frames = dataLength / bytesPerFrame
                                return (frames * 1000L) / sampleRate
                            }
                        }
                    }
                }
            } catch (_: Throwable) {}
        }

        // 2. MediaMetadataRetriever
        var retriever: MediaMetadataRetriever? = null
        try {
            retriever = MediaMetadataRetriever()
            retriever.setDataSource(filePath)
            val durStr = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
            if (durStr != null) {
                val dur = durStr.toLongOrNull()
                if (dur != null && dur > 0) return dur
            }
        } catch (_: Throwable) {
        } finally {
            try { retriever?.release() } catch (_: Throwable) {}
        }

        // 3. MediaExtractor fallback
        var extractor: MediaExtractor? = null
        try {
            extractor = MediaExtractor()
            extractor.setDataSource(filePath)
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("audio/") && format.containsKey(MediaFormat.KEY_DURATION)) {
                    val durUs = format.getLong(MediaFormat.KEY_DURATION)
                    if (durUs > 0) return durUs / 1000L
                }
            }
        } catch (_: Throwable) {
        } finally {
            try { extractor?.release() } catch (_: Throwable) {}
        }

        return null
    }

    /**
     * Extracts waveform peaks incrementally without retaining full PCM in memory.
     * Memory usage is O(numPeaks) instead of O(audioLength).
     */
    fun extractWaveformOnly(filePath: String, numPeaks: Int = 200): WaveformResult? {
        val file = File(filePath)
        if (!file.exists() || file.length() < 12) return null

        // Get duration first
        val durationMs = getAudioMetadata(filePath) ?: return null
        if (durationMs <= 0) return null

        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(filePath)
            var audioTrackIdx = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val tf = extractor.getTrackFormat(i)
                val mime = tf.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("audio/")) {
                    audioTrackIdx = i
                    format = tf
                    break
                }
            }
            if (audioTrackIdx < 0 || format == null) return null
            extractor.selectTrack(audioTrackIdx)

            val sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val channelCount = try { format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) } catch (_: Exception) { 1 }
            val mime = format.getString(MediaFormat.KEY_MIME) ?: return null

            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            val totalSamples = (sampleRate.toLong() * durationMs) / 1000L
            val samplesPerPeak = max(1L, totalSamples / numPeaks)
            
            // Preserve actual silence/quiet phonemes for VAD. The Flutter
            // painter alone supplies the minimum visible waveform height.
            val peaks = mutableListOf<Double>()
            var currentPeakMax = 0.0
            var samplesInCurrentPeak = 0L
            var totalSamplesProcessed = 0L
            
            val bufferInfo = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            val timeoutUs = 10000L

            while (!outputDone) {
                if (!inputDone) {
                    val inputIdx = codec.dequeueInputBuffer(timeoutUs)
                    if (inputIdx >= 0) {
                        val inputBuf = codec.getInputBuffer(inputIdx) ?: continue
                        val sampleSize = extractor.readSampleData(inputBuf, 0)
                        if (sampleSize < 0) {
                            codec.queueInputBuffer(inputIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            val pts = extractor.sampleTime
                            codec.queueInputBuffer(inputIdx, 0, sampleSize, pts, 0)
                            extractor.advance()
                        }
                    }
                }

                val outputIdx = codec.dequeueOutputBuffer(bufferInfo, timeoutUs)
                if (outputIdx >= 0) {
                    if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        outputDone = true
                    }
                    val outputBuf = codec.getOutputBuffer(outputIdx)
                    if (outputBuf != null && bufferInfo.size > 0) {
                        outputBuf.position(bufferInfo.offset)
                        outputBuf.limit(bufferInfo.offset + bufferInfo.size)
                        val outputFormat = codec.outputFormat
                        val isFloat = try {
                            outputFormat.getInteger(MediaFormat.KEY_PCM_ENCODING) == android.media.AudioFormat.ENCODING_PCM_FLOAT
                        } catch (_: Exception) { false }
                        
                        if (isFloat) {
                            val floatBuf = outputBuf.order(ByteOrder.nativeOrder()).asFloatBuffer()
                            val frameCount = floatBuf.remaining() / channelCount
                            for (f in 0 until frameCount) {
                                var mono = 0.0f
                                for (ch in 0 until channelCount) {
                                    mono += floatBuf.get()
                                }
                                mono /= channelCount
                                val amp = abs(mono.toDouble()).coerceAtMost(1.0)
                                if (amp > currentPeakMax) currentPeakMax = amp
                                samplesInCurrentPeak++
                                totalSamplesProcessed++
                                if (samplesInCurrentPeak >= samplesPerPeak) {
                                    peaks.add(currentPeakMax.coerceIn(0.0, 1.0))
                                    currentPeakMax = 0.0
                                    samplesInCurrentPeak = 0
                                }
                            }
                        } else {
                            // PCM16
                            val shortBuf = outputBuf.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                            val frameCount = shortBuf.remaining() / channelCount
                            for (f in 0 until frameCount) {
                                var mono = 0.0f
                                for (ch in 0 until channelCount) {
                                    mono += shortBuf.get().toFloat() / 32768.0f
                                }
                                mono /= channelCount
                                val amp = abs(mono.toDouble()).coerceAtMost(1.0)
                                if (amp > currentPeakMax) currentPeakMax = amp
                                samplesInCurrentPeak++
                                totalSamplesProcessed++
                                if (samplesInCurrentPeak >= samplesPerPeak) {
                                    peaks.add(currentPeakMax.coerceIn(0.0, 1.0))
                                    currentPeakMax = 0.0
                                    samplesInCurrentPeak = 0
                                }
                            }
                        }
                    }
                    codec.releaseOutputBuffer(outputIdx, false)
                }
            }
            
            // Flush remaining samples
            if (samplesInCurrentPeak > 0) {
                peaks.add(currentPeakMax.coerceIn(0.0, 1.0))
            }

            return WaveformResult(durationMs, peaks)
        } catch (e: Exception) {
            e.printStackTrace()
            return null
        } finally {
            try { codec?.stop() } catch (_: Exception) {}
            try { codec?.release() } catch (_: Exception) {}
            extractor.release()
        }
    }

    /**
     * Decodes an audio file to a 16kHz mono float array with optional cancellation check.
     */
    fun decodeTo16kHzMonoPcm(filePath: String, isCancelled: (() -> Boolean)? = null,
                            startMs: Long? = null, endMs: Long? = null): DecodedPcmBuffer {
        if (startMs != null || endMs != null) {
            require(startMs != null && endMs != null) { "Both range endpoints are required" }
            return AudioRangeDecoder.decode(filePath, startMs, endMs, isCancelled)
        }
        val result = decodeAudioFull(filePath, numPeaks = 0, isCancelled = isCancelled)
        return result?.pcm ?: DecodedPcmBuffer(FloatArray(0), 0)
    }

    /**
     * Decodes audio and computes real duration, 16kHz mono PCM, and real waveform peaks.
     */
    fun decodeAudioFull(filePath: String, numPeaks: Int = 200, isCancelled: (() -> Boolean)? = null): DecodedAudioResult? {
        val file = File(filePath)
        if (!file.exists() || file.length() < 12) return null

        if (isCancelled?.invoke() == true) return null

        // Try direct WAV parser first
        if (filePath.endsWith(".wav", ignoreCase = true)) {
            val wavResult = parseWavFile(file, numPeaks, isCancelled)
            if (wavResult != null) return wavResult
        }

        if (isCancelled?.invoke() == true) return null

        // MediaCodec decoding for compressed formats and fallback
        return decodeWithMediaCodec(file, numPeaks, isCancelled)
    }

    private fun parseWavFile(file: File, numPeaks: Int, isCancelled: (() -> Boolean)?): DecodedAudioResult? {
        try {
            FileInputStream(file).use { fis ->
                val header = ByteArray(12)
                if (fis.read(header) < 12) return null
                val riff = String(header, 0, 4)
                val wave = String(header, 8, 4)
                if (riff != "RIFF" || wave != "WAVE") return null

                var channels = 1
                var sampleRate = 16000
                var bitsPerSample = 16
                var audioFormat = 1
                var dataChunkSize = 0L

                val chunkHeader = ByteArray(8)
                while (fis.read(chunkHeader) == 8) {
                    if (isCancelled?.invoke() == true) return null

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

                        // For WAVE_FORMAT_EXTENSIBLE (0xFFFE), check subformat GUID (need >= 26 bytes for short at offset 24)
                        if (audioFormat == 0xFFFE && fmtData.size >= 26) {
                            val subFormatCode = fmtBuf.getShort(24).toInt() and 0xFFFF
                            audioFormat = subFormatCode // 1 for PCM, 3 for IEEE Float
                        }
                        if (chunkSize % 2L != 0L) {
                            fis.skip(1)
                        }
                    } else if (chunkId == "data") {
                        dataChunkSize = chunkSize
                        break
                    } else {
                        // Skip non-data chunks with word alignment
                        val skipBytes = if (chunkSize % 2L != 0L) chunkSize + 1L else chunkSize
                        var skipped = 0L
                        while (skipped < skipBytes) {
                            val s = fis.skip(skipBytes - skipped)
                            if (s <= 0) break
                            skipped += s
                        }
                    }
                }

                if (dataChunkSize <= 0 || channels <= 0 || sampleRate <= 0) return null
                if (bitsPerSample != 16 && bitsPerSample != 8 && bitsPerSample != 32) return null

                val bytesPerFrame = channels * (bitsPerSample / 8)
                if (bytesPerFrame <= 0) return null

                val totalFrames = dataChunkSize / bytesPerFrame
                val estimated16kSamples = ((totalFrames.toDouble() * 16000.0) / sampleRate.toDouble()).toInt() + 1000
                val resampler = DirectStreamingResampler16k(sampleRate, estimated16kSamples)

                val readBuffer = ByteArray(16384)
                val monoFloatChunk = FloatArray(readBuffer.size / bytesPerFrame + 4)
                var remainingData = dataChunkSize
                var remainderBytes = 0

                while (remainingData > 0 || remainderBytes > 0) {
                    if (isCancelled?.invoke() == true) return null

                    val toRead = min((readBuffer.size - remainderBytes).toLong(), remainingData).toInt()
                    val bytesRead = if (toRead > 0) fis.read(readBuffer, remainderBytes, toRead) else 0
                    if (bytesRead <= 0 && remainderBytes == 0) break
                    val actualBytesRead = if (bytesRead > 0) bytesRead else 0
                    remainingData -= actualBytesRead

                    val totalValidBytes = remainderBytes + actualBytesRead
                    val framesInChunk = totalValidBytes / bytesPerFrame
                    if (framesInChunk <= 0) {
                        remainderBytes = totalValidBytes
                        break
                    }

                    val bb = ByteBuffer.wrap(readBuffer, 0, framesInChunk * bytesPerFrame).order(ByteOrder.LITTLE_ENDIAN)

                    if (bitsPerSample == 16 && (audioFormat == 1 || audioFormat == 0xFFFE)) {
                        val sb = bb.asShortBuffer()
                        for (i in 0 until framesInChunk) {
                            var sum = 0.0f
                            for (c in 0 until channels) {
                                if (sb.hasRemaining()) {
                                    sum += sb.get().toFloat() / 32768.0f
                                }
                            }
                            monoFloatChunk[i] = sum / channels.toFloat()
                        }
                    } else if (bitsPerSample == 8) {
                        for (i in 0 until framesInChunk) {
                            var sum = 0.0f
                            for (c in 0 until channels) {
                                val byteVal = readBuffer[i * channels + c].toInt() and 0xFF
                                sum += (byteVal - 128) / 128.0f
                            }
                            monoFloatChunk[i] = sum / channels.toFloat()
                        }
                    } else if (bitsPerSample == 32 && audioFormat == 3) {
                        val fb = bb.asFloatBuffer()
                        for (i in 0 until framesInChunk) {
                            var sum = 0.0f
                            for (c in 0 until channels) {
                                if (fb.hasRemaining()) {
                                    sum += fb.get()
                                }
                            }
                            monoFloatChunk[i] = sum / channels.toFloat()
                        }
                    } else {
                        return null
                    }

                    resampler.feed(monoFloatChunk, framesInChunk)

                    val consumedBytes = framesInChunk * bytesPerFrame
                    remainderBytes = totalValidBytes - consumedBytes
                    if (remainderBytes > 0) {
                        System.arraycopy(readBuffer, consumedBytes, readBuffer, 0, remainderBytes)
                    }
                }

                val pcm = resampler.finish()
                val durationMs = (totalFrames.toDouble() * 1000.0 / sampleRate.toDouble()).toLong()
                val peaks = if (numPeaks > 0) computeWaveformPeaks(pcm.samples, pcm.validSampleCount, numPeaks) else emptyList()

                return DecodedAudioResult(durationMs, pcm, peaks)
            }
        } catch (_: Exception) {
            return null
        }
    }

    private fun decodeWithMediaCodec(file: File, numPeaks: Int, isCancelled: (() -> Boolean)?): DecodedAudioResult? {
        var extractor: MediaExtractor? = null
        var codec: MediaCodec? = null

        try {
            extractor = MediaExtractor()
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
                return null
            }

            extractor.selectTrack(audioTrackIndex)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
            var sampleRate = if (format.containsKey(MediaFormat.KEY_SAMPLE_RATE)) format.getInteger(MediaFormat.KEY_SAMPLE_RATE) else 44100
            var channelCount = if (format.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) else 2
            val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else 0L

            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            var pcmEncoding = if (format.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                format.getInteger(MediaFormat.KEY_PCM_ENCODING)
            } else {
                android.media.AudioFormat.ENCODING_PCM_16BIT
            }

            val estimated16kSamples = if (durationUs > 0) {
                ((durationUs / 1000000.0) * 16000.0).toInt() + 16000
            } else {
                16000 * 60
            }

            val resampler = DirectStreamingResampler16k(sampleRate, estimated16kSamples)
            val bufferInfo = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            var totalMonoSamples = 0L

            val tempMonoFloats = FloatArray(8192)

            while (!outputDone) {
                if (isCancelled?.invoke() == true) {
                    return null
                }

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
                    if (isCancelled?.invoke() == true) {
                        return null
                    }

                    val outputBuffer = codec.getOutputBuffer(outIndex)
                    if (outputBuffer != null && bufferInfo.size > 0) {
                        outputBuffer.position(bufferInfo.offset)
                        outputBuffer.limit(bufferInfo.offset + bufferInfo.size)

                        val safeChannels = if (channelCount > 0) channelCount else 1

                        if (pcmEncoding == android.media.AudioFormat.ENCODING_PCM_FLOAT) {
                            val fb = outputBuffer.order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
                            val frames = fb.remaining() / safeChannels
                            var frameIdx = 0
                            while (frameIdx < frames) {
                                val chunkFrames = min(frames - frameIdx, tempMonoFloats.size)
                                for (i in 0 until chunkFrames) {
                                    var sum = 0.0f
                                    for (c in 0 until safeChannels) {
                                        if (fb.hasRemaining()) {
                                            sum += fb.get()
                                        }
                                    }
                                    tempMonoFloats[i] = (sum / safeChannels.toFloat()).coerceIn(-1.0f, 1.0f)
                                }
                                resampler.feed(tempMonoFloats, chunkFrames)
                                totalMonoSamples += chunkFrames
                                frameIdx += chunkFrames
                            }
                        } else {
                            // Default to PCM 16-bit
                            val sb = outputBuffer.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                            val frames = sb.remaining() / safeChannels
                            var frameIdx = 0
                            while (frameIdx < frames) {
                                val chunkFrames = min(frames - frameIdx, tempMonoFloats.size)
                                for (i in 0 until chunkFrames) {
                                    var sum = 0.0f
                                    for (c in 0 until safeChannels) {
                                        if (sb.hasRemaining()) {
                                            sum += sb.get().toFloat() / 32768.0f
                                        }
                                    }
                                    tempMonoFloats[i] = (sum / safeChannels.toFloat()).coerceIn(-1.0f, 1.0f)
                                }
                                resampler.feed(tempMonoFloats, chunkFrames)
                                totalMonoSamples += chunkFrames
                                frameIdx += chunkFrames
                            }
                        }
                    }
                    codec.releaseOutputBuffer(outIndex, false)

                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        outputDone = true
                        break
                    }
                    // Drain only ready output here. Waiting after every decoded
                    // frame stalls feeding the next MP3 packet by 10 ms.
                    outIndex = codec.dequeueOutputBuffer(bufferInfo, 0)
                }

                if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val newFormat = codec.outputFormat
                    if (newFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                        sampleRate = newFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        resampler.updateSourceSampleRate(sampleRate)
                    }
                    if (newFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                        channelCount = newFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    }
                    if (newFormat.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                        pcmEncoding = newFormat.getInteger(MediaFormat.KEY_PCM_ENCODING)
                    }
                }
            }

            val pcm = resampler.finish()
            val durationMs = if (durationUs > 0) (durationUs / 1000L) else (totalMonoSamples.toDouble() * 1000.0 / sampleRate.toDouble()).toLong()
            val peaks = if (numPeaks > 0) computeWaveformPeaks(pcm.samples, pcm.validSampleCount, numPeaks) else emptyList()

            return DecodedAudioResult(durationMs, pcm, peaks)
        } catch (e: Throwable) {
            return null
        } finally {
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            try { extractor?.release() } catch (_: Throwable) {}
        }
    }

    private fun computeWaveformPeaks(samples16k: FloatArray, validCount: Int, targetPoints: Int): List<Double> {
        if (validCount <= 0 || samples16k.isEmpty()) return emptyList()
        val points = max(50, targetPoints)
        val blockSize = max(1, validCount / points)
        val peaks = mutableListOf<Double>()

        var i = 0
        while (i < validCount) {
            var maxAmp = 0.0f
            val end = min(i + blockSize, validCount)
            for (j in i until end step 2) {
                val amp = abs(samples16k[j])
                if (amp > maxAmp) maxAmp = amp
            }
            peaks.add(maxAmp.toDouble().coerceIn(0.0, 1.0))
            i += blockSize
        }
        return peaks
    }
}

