package dev.livelens.livelens.core

import android.os.Debug

/**
 * Benchmark-lite harness (PRD E-03): measured RTF, latency p50/p90, RAM and
 * an honest battery estimate — **self-reported stats for THIS device only**
 * (the aggregate opt-in telemetry is post-V1 and never touches this code).
 *
 * The scripted signal is a deterministic sum of sines (no randomness →
 * runs are comparable across models and app versions). Whisper still runs
 * its full encoder/decoder pass on it, so wall-clock timing is
 * representative; the *text* it hallucinates is irrelevant to the metrics.
 */
object ModelBenchmark {

    const val DEFAULT_ROUNDS = 8
    const val CHUNK_SECONDS = 5

    /**
     * Battery-estimate constants, documented so the number can be argued
     * with: sustained decode draw ≈ 2.5 W (big-core ARM cluster), a typical
     * 5000 mAh / 3.85 V pack stores ≈ 19.25 Wh → 693 J per percent.
     * est. %/min-of-audio = RTF × 60 s × 2.5 W ÷ 693 J ≈ RTF × 0.216.
     */
    private const val DECODE_WATTS = 2.5
    private const val BATTERY_JOULES_PER_PCT = 693.0

    /**
     * Runs the harness against an already-loaded [transcriber]. Blocking;
     * call off the main thread (loadModel callers already are).
     */
    fun run(transcriber: Transcriber, rounds: Int = DEFAULT_ROUNDS): Map<String, Any?> {
        transcriber.warmUp()

        val sig = scriptedSignal()
        // InferenceChunk carries 16-bit PCM; the scripted signal is unit-scale
        // float, so quantize (no dither — determinism matters for the harness).
        val pcm = ShortArray(sig.size) { (sig[it] * Short.MAX_VALUE).toInt().toShort() }
        val chunk = InferenceChunk(pcm, 0.0)
        val times = DoubleArray(rounds)
        for (i in 0 until rounds) {
            val t0 = System.nanoTime()
            transcriber.decode(chunk, "transcribe", "en")
            times[i] = (System.nanoTime() - t0) / 1_000_000.0
        }

        val sorted = times.sorted()
        val p50 = percentile(sorted, 0.50)
        val p90 = percentile(sorted, 0.90)
        val mean = times.average()
        val rtf = mean / 1000.0 / CHUNK_SECONDS

        val mem = Debug.MemoryInfo()
        Debug.getMemoryInfo(mem)

        return mapOf(
            "rounds" to rounds,
            "chunkSeconds" to CHUNK_SECONDS,
            "rtf" to rtf,
            "latencyP50Ms" to p50,
            "latencyP90Ms" to p90,
            "rssMb" to mem.totalPss / 1024.0,
            "batteryPctPerMin" to rtf * 60.0 * DECODE_WATTS / BATTERY_JOULES_PER_PCT,
        )
    }

    /** Interpolated percentile of an ascending list. */
    private fun percentile(sorted: List<Double>, q: Double): Double {
        if (sorted.isEmpty()) return 0.0
        val pos = q * (sorted.size - 1)
        val lo = pos.toInt()
        val hi = (lo + 1).coerceAtMost(sorted.size - 1)
        val frac = pos - lo
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }

    /** Deterministic 5 s 16 kHz signal — voiced-ish formant mix, half scale. */
    private fun scriptedSignal(): FloatArray {
        val n = CHUNK_SECONDS * SherpaWhisperTranscriber.SAMPLE_RATE
        val out = FloatArray(n)
        for (i in 0 until n) {
            val t = i / SherpaWhisperTranscriber.SAMPLE_RATE.toDouble()
            val v = 0.40 * kotlin.math.sin(2.0 * Math.PI * 220.0 * t) +
                0.30 * kotlin.math.sin(2.0 * Math.PI * 466.0 * t) +
                0.20 * kotlin.math.sin(2.0 * Math.PI * 900.0 * t) +
                0.05 * kotlin.math.sin(2.0 * Math.PI * 3_100.0 * t)
            out[i] = (v * 0.5).toFloat()
        }
        return out
    }
}
