package dev.livelens.livelens.core

/**
 * Maps recognizer-relative segment timestamps onto the session timeline
 * (B-06, architecture §3.3):
 *
 *     seg.t0 = chunk.audioOriginMs + seg.t0_rel
 *
 * When the pinned sherpa build provides no usable segment timestamps
 * (OpenQ 1), segments arrive as ordered text without times; [assignTimes]
 * then interpolates evenly across the chunk's audio span — the documented
 * fallback plan. Both paths are unit-tested.
 */
class ChunkTimeline(private val sampleRate: Int = 16_000) {

    /** A timestamped segment ready for EventEmitter / storage. */
    data class TimedSegment(
        val text: String,
        val t0Ms: Double,
        val t1Ms: Double,
    )

    /**
     * Absolute mapping path — used when the recognizer reports reliable
     * relative timestamps (ms within the chunk audio).
     */
    fun mapAbsolute(
        chunk: InferenceChunk,
        relSegments: List<RelSegment>,
    ): List<TimedSegment> {
        val msPerSample = 1000.0 / sampleRate
        val chunkDurationMs = chunk.samples.size * msPerSample

        return relSegments.map { seg ->
            val t0 = chunk.originMs + seg.relStartMs.coerceIn(0.0, chunkDurationMs)
            val t1 = chunk.originMs + seg.relEndMs.coerceIn(t0 - chunk.originMs, chunkDurationMs)
            TimedSegment(seg.text, t0, maxOf(t1, t0))
        }
    }

    /**
     * Interpolation fallback — distributes [texts] evenly across the
     * chunk's duration proportional to text length (longer lines get more
     * time than a naive even split; better matches speech pacing).
     */
    fun assignTimes(chunk: InferenceChunk, texts: List<String>): List<TimedSegment> {
        if (texts.isEmpty()) return emptyList()
        val msPerSample = 1000.0 / sampleRate
        val totalMs = chunk.samples.size * msPerSample

        val weights = texts.map { it.length.coerceAtLeast(1).toDouble() }
        val weightSum = weights.sum()

        val out = ArrayList<TimedSegment>(texts.size)
        var cursor = 0.0
        for ((text, w) in texts.zip(weights)) {
            val span = totalMs * (w / weightSum)
            out += TimedSegment(text, chunk.originMs + cursor, chunk.originMs + cursor + span)
            cursor += span
        }
        return out
    }

    /** Recognizer-relative segment input for [mapAbsolute]. */
    data class RelSegment(val text: String, val relStartMs: Double, val relEndMs: Double)
}