package com.example.local_ai_app

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

object AudioDecoder {

    /**
     * Decodes an audio file (MP3, M4A, AAC, WAV) to a 16kHz mono float array suitable for Whisper.
     */
    fun decodeTo16kHzMonoPcm(filePath: String): FloatArray {
        val file = File(filePath)
        if (!file.exists()) return FloatArray(0)

        // If it's standard 16kHz 16-bit WAV, read PCM directly
        if (filePath.endsWith(".wav", ignoreCase = true)) {
            val wavFloats = readWavIf16kHz(file)
            if (wavFloats != null) return wavFloats
        }

        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(filePath)
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
                return FloatArray(0)
            }

            extractor.selectTrack(audioTrackIndex)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
            val sampleRate = if (format.containsKey(MediaFormat.KEY_SAMPLE_RATE)) format.getInteger(MediaFormat.KEY_SAMPLE_RATE) else 44100
            val channelCount = if (format.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) else 2

            val codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            val rawPcmList = mutableListOf<Short>()
            val bufferInfo = MediaCodec.BufferInfo()
            var isEOS = false

            while (!isEOS) {
                val inIndex = codec.dequeueInputBuffer(10000)
                if (inIndex >= 0) {
                    val inputBuffer = codec.getInputBuffer(inIndex)
                    if (inputBuffer != null) {
                        val sampleSize = extractor.readSampleData(inputBuffer, 0)
                        if (sampleSize < 0) {
                            codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            isEOS = true
                        } else {
                            codec.queueInputBuffer(inIndex, 0, sampleSize, extractor.sampleTime, 0)
                            extractor.advance()
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
                            rawPcmList.add(shortBuffer.get())
                        }
                    }
                    codec.releaseOutputBuffer(outIndex, false)
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        isEOS = true
                        break
                    }
                    outIndex = codec.dequeueOutputBuffer(bufferInfo, 10000)
                }
            }

            codec.stop()
            codec.release()
            extractor.release()

            return resampleAndMixDownTo16kHz(rawPcmList, sampleRate, channelCount)
        } catch (e: Exception) {
            try { extractor.release() } catch (_: Exception) {}
            return FloatArray(0)
        }
    }

    private fun readWavIf16kHz(file: File): FloatArray? {
        try {
            val bytes = file.readBytes()
            if (bytes.size < 44) return null
            val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            val channels = buffer.getShort(22).toInt()
            val sampleRate = buffer.getInt(24)
            val bitsPerSample = buffer.getShort(34).toInt()

            if (sampleRate == 16000 && bitsPerSample == 16) {
                buffer.position(44)
                val shortBuffer = buffer.asShortBuffer()
                val shortCount = (bytes.size - 44) / 2
                val result = FloatArray(shortCount / channels)
                for (i in 0 until result.size) {
                    var sum = 0.0f
                    for (c in 0 until channels) {
                        if (shortBuffer.hasRemaining()) {
                            sum += shortBuffer.get().toFloat() / 32768.0f
                        }
                    }
                    result[i] = sum / channels.toFloat()
                }
                return result
            }
        } catch (_: Exception) {}
        return null
    }

    private fun resampleAndMixDownTo16kHz(
        pcmShorts: List<Short>,
        origSampleRate: Int,
        channels: Int
    ): FloatArray {
        if (pcmShorts.isEmpty()) return FloatArray(0)

        val totalFrames = pcmShorts.size / channels
        val monoFloats = FloatArray(totalFrames)

        for (i in 0 until totalFrames) {
            var sum = 0.0f
            for (c in 0 until channels) {
                val idx = i * channels + c
                if (idx < pcmShorts.size) {
                    sum += pcmShorts[idx].toFloat() / 32768.0f
                }
            }
            monoFloats[i] = sum / channels.toFloat()
        }

        if (origSampleRate == 16000) {
            return monoFloats
        }

        // Linear interpolation resampling to 16000 Hz
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
}
