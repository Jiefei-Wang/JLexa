package com.example.local_ai_app

/** Host JVM regression probe; no Android runtime or inference library required. */
object AudioEnergyProbe {
    @JvmStatic fun main(args: Array<String>) {
        val samples = FloatArray(327) { index ->
            when {
                index < 160 -> if (index % 2 == 0) 0.5f else -0.5f
                index < 320 -> 0f
                else -> 0.25f
            }
        }
        val energy = AudioEnergy.fromPcm(samples, samples.size, 1237)
        val packet = energy.toMap()
        check(packet["startMs"] == 1237L && packet["stepMs"] == 10)
        check(packet["values"] == listOf(0.25, 0.0, 0.0625))
        check(AudioEnergy.fromPcm(samples, 160, 0).toMap()["values"] == listOf(0.25))
        samples.fill(1f)
        check(energy.toMap()["values"] == listOf(0.25, 0.0, 0.0625)) // no retained PCM
        fun rejects(block: () -> Unit) {
            check(runCatching(block).exceptionOrNull() is IllegalArgumentException)
        }
        rejects { AudioEnergy.fromPcm(FloatArray(0), 0, 0) }
        rejects { AudioEnergy.fromPcm(samples, samples.size + 1, 0) }
        rejects { AudioEnergy.fromPcm(samples, 1, -1) }
        rejects { AudioEnergy.fromPcm(floatArrayOf(Float.NaN), 1, 0) }
        val cache = AudioEnergy.Cache()
        cache.put("lesson.wav", energy)
        check(cache.find("lesson.wav", 1238, 1257) === energy)
        check(cache.find("lesson.wav", 1237, 1258) == null) // actual EOF, not rounded bin end
        check(cache.find("lesson.wav", 1236, 1240) == null)
        check(cache.find("other.wav", 1238, 1250) == null)
        check(cache.find("lesson.wav", 1250, 1250) == null)
        val newer = AudioEnergy.fromPcm(floatArrayOf(0f), 1, 9000)
        cache.put("other.wav", newer)
        check(cache.find("lesson.wav", 1238, 1250) == null)
        cache.close()
        // Simulate a decoder finishing after cleanup; no stale envelope survives.
        val worker = Thread { repeat(1000) { cache.put("lesson.wav", energy) } }
        worker.start()
        worker.join()
        check(cache.find("lesson.wav", 1238, 1250) == null)
        println("PASS: 10ms mean square, partial EOF, valid sample count, absolute offsets, empty/invalid input, range/path cache, cleanup race")
    }
}
