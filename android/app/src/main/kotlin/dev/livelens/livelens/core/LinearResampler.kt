package dev.livelens.livelens.core

import kotlin.math.floor

/**
 * Chunk-linear resampler to 16 kHz mono PCM16 (A-04).
 *
 * Architecture §3.3: "cheap polyphase-less linear resampler … adequate
 * post-VAD; reject any offer to run VAD on 48k."
 *
 * Correctness model (verified by unit tests):
 * - Output k is placed at input-stream time t = k · step (step = inRate/outRate).
 * - An output is emitted once BOTH surrounding input samples exist; the
 *   pending output carries across chunk boundaries via [outCount].
 * - Interpolation across the seam uses the previous chunk's final sample,
 *   so chunked processing is BIT-EXACT equal to single-shot processing.
 *
 * Not thread-safe by design: owned by the single capture thread (§3.2).
 */
class LinearResampler(
    private val inputRate: Int,
    private val outputRate: Int = 16_000,
) {
    init {
        require(inputRate > 0 && outputRate > 0)
    }

    private val step = inputRate.toDouble() / outputRate

    /** Total input samples consumed so far (global stream position). */
    private var totalInput = 0L

    /** Number of outputs emitted so far; next output time = outCount·step. */
    private var outCount = 0L

    /** Final sample of the previous chunk (seam anchor); NaN initially. */
    private var carry = Double.NaN

    /**
     * Resamples one chunk of PCM16. Returns a possibly-empty array (a chunk
     * too short to complete an interpolation pair holds its samples).
     */
    fun process(input: ShortArray): ShortArray {
        if (input.isEmpty()) return ShortArray(0)

        val prevTotal = totalInput
        val newTotal = prevTotal + input.size
        val out = ArrayList<Short>(input.size / 2 + 1)

        while (true) {
            val t = outCount * step
            val i0 = floor(t).toLong()
            val frac = t - i0
            // Sample i0 must exist; i0+1 only when actually interpolating.
            // frac == 0 ⇒ pure copy of s0 (identity-rate streams pass through
            // untouched, and no stream-final sample is ever stranded).
            if (i0 > newTotal - 1) break
            if (frac > 0 && i0 + 1 > newTotal - 1) break
            val s0: Double
            val s1: Double
            if (i0 == prevTotal - 1 && prevTotal > 0) {
                // Seam: left neighbor is the previous chunk's last sample.
                s0 = carry
                s1 = input[((i0 + 1) - prevTotal).toInt()].toDouble()
            } else {
                val local0 = (i0 - prevTotal).toInt()
                s0 = input[local0].toDouble()
                s1 = if (local0 + 1 < input.size) {
                    input[local0 + 1].toDouble()
                } else {
                    check(frac == 0.0) { "interpolation needs right neighbor" }
                    s0 // unused when frac == 0
                }
            }

            val v = s0 + (s1 - s0) * frac
            out += v.coerceIn(-32768.0, 32767.0).toInt().toShort()
            outCount++
        }

        totalInput = newTotal
        carry = input[input.size - 1].toDouble()

        return out.toShortArray()
    }
}