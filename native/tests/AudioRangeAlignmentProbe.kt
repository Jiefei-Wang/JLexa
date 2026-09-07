package com.example.local_ai_app

import java.io.File
import kotlin.math.sqrt

/** Compares separate seeks with the pre-existing sequential whole-file decoder. */
object AudioRangeAlignmentProbe {
    @JvmStatic fun main(args: Array<String>) {
        val source = args[0]
        val started = System.nanoTime()
        val full = AudioDecoder.decodeTo16kHzMonoPcm(source)
        check(full.validSampleCount > 0)
        println("REFERENCE full_decode_ms=${(System.nanoTime()-started)/1_000_000} samples=${full.validSampleCount}")
        val duration = full.validSampleCount / 16L
        val ranges = listOf(0L to 999L, 123L to 2345L, duration/2 to duration/2+1501,
            duration-1000 to duration+500)
        for ((start,end) in ranges) {
            val began = System.nanoTime()
            val pcm = AudioRangeDecoder.decode(source,start,end)
            val available = minOf(((end-start)*16).toInt(),full.validSampleCount-(start*16).toInt())
            check(kotlin.math.abs(pcm.validSampleCount-available) <= 1) { "Length mismatch: $start/$end ${pcm.validSampleCount}/$available" }
            var error=0.0
            var power=0.0
            for(i in 0 until minOf(pcm.validSampleCount,available)) {
                val expected=full.samples[(start*16).toInt()+i].toDouble()
                val delta=pcm.samples[i]-expected
                error+=delta*delta
                power+=expected*expected
            }
            val rmse=sqrt(error/maxOf(power,1e-12))
            println("ALIGN start_ms=$start end_ms=$end decode_ms=${(System.nanoTime()-began)/1_000_000} samples=${pcm.validSampleCount} scaled_rmse=$rmse")
            check(rmse<0.01) { "PCM alignment failed" }
        }
        var polls=0
        check(runCatching { AudioRangeDecoder.decode(source,duration/2,duration/2+1000) { ++polls>30 } }.isFailure)
        println("Mid-decode cancellation: PASS")
        println("Audio alignment probe: PASS")
    }
}
