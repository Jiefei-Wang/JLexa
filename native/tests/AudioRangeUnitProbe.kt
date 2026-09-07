package com.example.local_ai_app

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs

object AudioRangeUnitProbe {
    private fun fixture(file: File, rate: Int) {
        val frames = rate * 3
        val bytes = ByteBuffer.allocate(56 + frames * 8).order(ByteOrder.LITTLE_ENDIAN)
        bytes.put("RIFF".toByteArray()).putInt(bytes.capacity()-8).put("WAVE".toByteArray())
        bytes.put("JUNK".toByteArray()).putInt(3).put(byteArrayOf(7,8,9,0))
        bytes.put("fmt ".toByteArray()).putInt(16).putShort(3).putShort(2).putInt(rate).putInt(rate*8).putShort(8).putShort(32)
        bytes.put("data".toByteArray()).putInt(frames*8)
        for (frame in 0 until frames) {
            val sample = -0.75f + frame.toFloat() / rate / 2
            bytes.putFloat(sample - 0.1f).putFloat(sample + 0.1f)
        }
        file.writeBytes(bytes.array())
    }

    @JvmStatic fun main(args: Array<String>) {
        val directory = File(args[0]).also { it.mkdirs() }
        for (rate in listOf(8000, 16000, 44100, 48000)) {
            val source = File(directory, "range-unit-$rate.wav")
            fixture(source, rate)
            val start = 123L
            val end = 2345L
            val pcm = AudioRangeDecoder.decode(source.path, start, end)
            check(pcm.validSampleCount == ((end-start)*16).toInt())
            for (i in pcm.samples.indices) {
                val expected = -0.75 + (start / 1000.0 + i / 16000.0) / 2
                check(abs(pcm.samples[i]-expected) < 2e-7) { "Resampling mismatch at $rate / $i" }
            }
            val eof = AudioRangeDecoder.decode(source.path, 2900, 4000)
            check(eof.validSampleCount == 1600)
            check(AudioRangeDecoder.decode(source.path, 4000, 5000).validSampleCount == 0)
            check(runCatching { AudioRangeDecoder.decode(source.path, -1, 10) }.isFailure)
            check(runCatching { AudioRangeDecoder.decode(source.path, 10, 10) }.isFailure)
            var polls = 0
            check(runCatching { AudioRangeDecoder.decode(source.path, 0, 3000) { ++polls > 6 } }.isFailure)
            val cancelled = File(directory, "range-unit-$rate-cancel.wav")
            check(runCatching { AudioClipExporter.export(source.path, 0, 3000, cancelled.path) { true } }.isFailure)
            check(!cancelled.exists())
            val output = File(directory, "range-unit-$rate-clip.wav")
            output.delete() // Fixture-owned output only, for repeatable diagnostic runs.
            val result = AudioClipExporter.export(source.path, start, end, output.path)
            check(result["path"] == output.path && result["durationMs"] == end-start)
            val roundtrip = AudioRangeDecoder.decode(output.path, 0, end-start)
            check(roundtrip.validSampleCount == pcm.validSampleCount)
            for (i in pcm.samples.indices) check(abs(roundtrip.samples[i]-pcm.samples[i]) <= 1f/32768)
            check(directory.listFiles()!!.none { it.name.startsWith(".jlexa-clip-") })
            println("WAV rate=$rate stereo/downmix/range/EOF/cancel/export PASS")
        }
        println("Audio range unit probe: PASS")
    }
}
