package com.example.local_ai_app

import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.CancellationException

object AudioClipExporter {
    /** Publishes only a complete, synced WAV in the requested local destination directory. */
    @Synchronized
    fun export(audioPath: String, startMs: Long, endMs: Long, outputPath: String,
               cancelled: (() -> Boolean)? = null): Map<String, Any> {
        val source = File(audioPath).canonicalFile
        val destination = File(outputPath).canonicalFile
        require(source != destination) { "Clip destination must differ from source" }
        require(!destination.exists()) { "Clip destination already exists" }
        val parent = destination.parentFile ?: throw IllegalArgumentException("Clip destination needs a parent directory")
        require(parent.isDirectory || parent.mkdirs()) { "Cannot create clip directory" }
        val pcm = AudioRangeDecoder.decode(source.path, startMs, endMs, cancelled)
        require(pcm.validSampleCount > 0) { "Requested clip has no decodable audio" }
        val temporary = File.createTempFile(".jlexa-clip-", ".wav.part", parent)
        try {
            FileOutputStream(temporary).use { output ->
                val bytes = pcm.validSampleCount.toLong() * 2
                require(bytes + 36 <= 0xffffffffL) { "Clip exceeds WAV size limit" }
                val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
                header.put("RIFF".toByteArray(Charsets.US_ASCII)).putInt((bytes + 36).toInt())
                header.put("WAVEfmt ".toByteArray(Charsets.US_ASCII)).putInt(16)
                header.putShort(1).putShort(1).putInt(16000).putInt(32000).putShort(2).putShort(16)
                header.put("data".toByteArray(Charsets.US_ASCII)).putInt(bytes.toInt())
                output.write(header.array())
                val chunk = ByteBuffer.allocate(8192).order(ByteOrder.LITTLE_ENDIAN)
                var index = 0
                while (index < pcm.validSampleCount) {
                    if (cancelled?.invoke() == true) throw CancellationException("Audio clip export cancelled")
                    chunk.clear()
                    repeat(minOf(chunk.capacity() / 2, pcm.validSampleCount - index)) {
                        val sample = pcm.samples[index++]
                        chunk.putShort((sample.coerceIn(-1f, 1f) * 32768f).toInt().coerceIn(-32768, 32767).toShort())
                    }
                    output.write(chunk.array(), 0, chunk.position())
                }
                output.fd.sync()
            }
            if (cancelled?.invoke() == true) throw CancellationException("Audio clip export cancelled")
            check(!destination.exists()) { "Clip destination already exists" }
            Files.move(temporary.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE)
            return mapOf("path" to outputPath, "durationMs" to pcm.validSampleCount / 16L, "sampleRate" to 16000)
        } finally {
            temporary.delete()
        }
    }
}
