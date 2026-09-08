package com.example.local_ai_app

/** Unscaled mean-square energy of exact 16 kHz mono PCM, with absolute time origin. */
internal class AudioEnergy private constructor(
    val startMs: Long,
    private val sampleCount: Int,
    private val values: List<Double>
) {
    fun toMap(): Map<String, Any> = mapOf(
        "startMs" to startMs, "stepMs" to 10, "values" to values
    )

    private fun contains(start: Long, end: Long): Boolean =
        start >= startMs && end > start && (end - startMs) <= sampleCount / 16.0

    companion object {
        fun fromPcm(samples: FloatArray, validSampleCount: Int, startMs: Long): AudioEnergy {
            require(startMs >= 0) { "Audio energy start must be non-negative" }
            require(validSampleCount in 1..samples.size) { "Audio energy requires non-empty valid PCM" }
            val values = ArrayList<Double>((validSampleCount - 1) / 160 + 1)
            var offset = 0
            while (offset < validSampleCount) {
                val end = minOf(offset + 160, validSampleCount)
                var sum = 0.0
                for (i in offset until end) {
                    val sample = samples[i].toDouble()
                    require(sample.isFinite()) { "Audio energy PCM contains a non-finite sample" }
                    sum += sample * sample
                }
                // At EOF, divide by the actual remaining samples, never zero padding.
                values.add(sum / (end - offset))
                offset = end
            }
            return AudioEnergy(startMs, validSampleCount, values)
        }
    }

    /** One small envelope only; PCM never survives the decoding request. */
    class Cache {
        private var entry: Pair<String, AudioEnergy>? = null
        private var closed = false

        @Synchronized fun find(path: String, startMs: Long, endMs: Long): AudioEnergy? =
            entry?.takeIf { !closed && it.first == path && it.second.contains(startMs, endMs) }?.second

        @Synchronized fun put(path: String, energy: AudioEnergy) {
            if (!closed) entry = path to energy
        }

        // Closing and publishing share the lock: an in-flight IO request cannot repopulate it.
        @Synchronized fun close() {
            closed = true
            entry = null
        }
    }
}
