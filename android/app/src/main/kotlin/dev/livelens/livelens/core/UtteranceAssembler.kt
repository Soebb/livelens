package dev.livelens.livelens.core

/**
 * Buffers 16 kHz PCM and turns VAD segment boundaries into padded
 * [Utterance]s (B-02: pad 100 ms on both sides of speech, PRD §B-02).
 *
 * Pure Kotlin (unit-tested); [VadWorker] feeds it sherpa-onnx segment
 * bounds. The engine guarantees blocks are fed in order, so the internal
 * buffer is one contiguous run of audio.
 *
 * All indices are absolute sample positions since the stream started
 * ([reset] zeroes them).
 */
class UtteranceAssembler(
    private val sampleRate: Int = 16_000,
    prePadMs: Double = 100.0,
    postPadMs: Double = 100.0,
) {
    private val msPerSample = 1000.0 / sampleRate
    private val prePadSamples = (prePadMs / msPerSample).toLong()
    private val postPadSamples = (postPadMs / msPerSample).toLong()

    private var buf = ShortArray(1 shl 13)
    private var bufLen = 0

    /** Absolute sample index of `buf[0]`. */
    private var bufStart = 0L

    /** Absolute sample index one past the last fed sample. */
    private var total = 0L

    /** Session-timeline origin of `buf[0]`. */
    private var bufOriginMs = 0.0

    val pendingSamples: Int get() = bufLen
    fun pendingMs(): Double = bufLen * msPerSample

    /** Appends one contiguous block; [originMs] is the origin of samples[0]. */
    fun feed(samples: ShortArray, originMs: Double) {
        if (samples.isEmpty()) return
        if (bufLen == 0) bufOriginMs = originMs
        ensureCapacity(bufLen + samples.size)
        System.arraycopy(samples, 0, buf, bufLen, samples.size)
        bufLen += samples.size
        total += samples.size
    }

    /**
     * Builds the padded utterance for the VAD segment `[startAbs, endAbs)`
     * and consumes buffered audio up to `endAbs + postPad` (clamped to what
     * has actually arrived). Returns null if the segment was already
     * trimmed away (e.g. between [reset]s).
     */
    fun segment(startAbs: Long, endAbs: Long): Utterance? {
        val from = maxOf(startAbs - prePadSamples, bufStart)
        val to = minOf(endAbs + postPadSamples, total)
        if (to <= from) return null
        val off = (from - bufStart).toInt()
        val len = (to - from).toInt()
        val samples = buf.copyOfRange(off, off + len)
        val originMs = bufOriginMs + (from - bufStart) * msPerSample
        shift((to - bufStart).toInt())
        return Utterance(samples, sampleRate, originMs)
    }

    /**
     * During silence: keep only the last [prePadMs] as future pre-roll so
     * the buffer cannot grow unboundedly between utterances.
     */
    fun trimToPreRoll() {
        val keep = minOf(prePadSamples, bufLen.toLong()).toInt()
        if (keep < bufLen) shift(bufLen - keep)
    }

    /**
     * Mid-speech partial emit (latency): returns the buffered audio MINUS
     * the last [keepTailMs] (kept as continuation primer) as an
     * [Utterance], consuming the emitted span. Call while VAD reports
     * ongoing speech and [pendingMs] exceeds the partial-decode threshold;
     * the still-buffered tail merges into the eventual VAD segment.
     *
     * Returns null when the buffer holds no more than the tail.
     */
    fun cutPartial(keepTailMs: Double): Utterance? {
        val keep = (keepTailMs / msPerSample).toInt().coerceIn(0, bufLen)
        if (bufLen <= keep) return null
        val emitLen = bufLen - keep
        val samples = buf.copyOfRange(0, emitLen)
        val originMs = bufOriginMs
        shift(emitLen)
        return Utterance(samples, sampleRate, originMs)
    }

    fun reset() {
        bufLen = 0
        bufStart = 0L
        total = 0L
        bufOriginMs = 0.0
    }

    private fun shift(count: Int) {
        if (count <= 0) return
        System.arraycopy(buf, count, buf, 0, bufLen - count)
        bufLen -= count
        bufStart += count
        bufOriginMs += count * msPerSample
    }

    private fun ensureCapacity(n: Int) {
        if (buf.size >= n) return
        var cap = buf.size
        while (cap < n) cap *= 2
        buf = buf.copyOf(cap)
    }
}
