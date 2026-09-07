package com.example.local_ai_app

import java.io.DataInputStream
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.sqrt

/** Standalone app_process diagnostic; never installs an APK or changes app data. */
object AudioRangeProbe {
    @JvmStatic fun main(args: Array<String>) {
        val source = args[0]
        val start = args[1].toLong()
        val end = args[2].toLong()
        val output = args[3]
        val began = System.nanoTime()
        val pcm = AudioRangeDecoder.decode(source, start, end)
        println("RANGE decode_ms=${(System.nanoTime() - began)/1_000_000} count=${pcm.validSampleCount}")
        check(pcm.validSampleCount > 0 && pcm.validSampleCount <= (end-start)*16)
        if (args.size > 4) {
            val ref = DataInputStream(FileInputStream(args[4])).use { input ->
                FloatArray(File(args[4]).length().toInt()/4) { input.readFloat() }
            }
            check(ref.size == pcm.validSampleCount)
            var error = 0.0
            var power = 0.0
            var maximum = 0.0
            for (i in ref.indices) {
                val delta = (ref[i] - pcm.samples[i]).toDouble()
                error += delta * delta
                power += ref[i].toDouble() * ref[i]
                maximum = maxOf(maximum, abs(delta))
            }
            println("REFERENCE scaled_rmse=${sqrt(error/maxOf(power,1e-12))} max_error=$maximum")
            check(sqrt(error/maxOf(power,1e-12)) < 0.01) { "Range PCM does not align with full decode" }
        }
        val result = AudioClipExporter.export(source, start, end, output)
        val bytes = File(output).readBytes()
        val header = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        check(String(bytes,0,4) == "RIFF" && String(bytes,8,4) == "WAVE")
        check(header.getInt(24)==16000 && header.getShort(22).toInt()==1 && header.getShort(34).toInt()==16)
        check(header.getInt(40)==pcm.validSampleCount*2 && bytes.size==44+pcm.validSampleCount*2)
        check(result["durationMs"] == pcm.validSampleCount/16L)
        check(runCatching { AudioClipExporter.export(source,start,end,output) }.isFailure)
        check(runCatching { AudioClipExporter.export(source,start,end,source) }.isFailure)
        check(runCatching { AudioClipExporter.export(source,start,end,"$output.cancel") { true } }.isFailure)
        check(!File("$output.cancel").exists())
        println("EXPORT $result")
        println("Audio range/export probe: PASS")
    }
}
