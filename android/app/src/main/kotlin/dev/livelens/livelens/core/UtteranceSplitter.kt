package dev.livelens.livelens.core

/**
 * One VAD-assembled utterance entering the pipeline (B-02 output).
 *
 * @param samples PCM16 mono @ [sampleRate]
 * @param sampleRate always 16 kHz post-resampler (A-04)
 * @param audioOriginMs session-timeline position of samples[0]
 */
class Utterance(
    val samples: ShortArray,
    val sampleRate: Int,
    val audioOriginMs: Double,
)

/**
 * One unit of work handed to the inference executor (B-04).
 *
 * @param samples may include leading primer audio on split continuations
 * @param originMs session-timeline position of samples[0] — primer INCLUDED,
 *   so recognizer-relative timestamps map honestly via ChunkTimeline (B-06)
 */
class InferenceChunk(
    val samples: ShortArray,
    val originMs: Double,
)

/**
 * Hard-splits long utterances at 8 s, carrying a 320 ms trailing primer
 * into each continuation for context (B-03, architecture §3.3).
 *
 * "dedupe on recognition is a P2 nicety — accept rare dupes in V1":
 * the primer intentionally overlaps the previous chunk's tail; the model
 * may re-emit those words. Accepted per spec.
 *
 * 8 s (down from the original 12 s): decode time scales with chunk length
 * and long buffers are the primary Whisper hallucination-loop trigger —
 * shorter windows cut both first-decode latency and loop risk.
 *
 * Pure Kotlin; owned by the VAD thread side of the pipeline.
 */
class UtteranceSplitter(private val sampleRate: Int = 16_000) {

    companion object {
        /** Max chunk length before forced split (ms). */
        const val MAX_CHUNK_MS = 8_000.0

        /** Trailing context audio carried into continuation chunks (ms). */
        const val PRIMER_MS = 320.0
    }

    private val maxChunkSamples = (MAX_CHUNK_MS * sampleRate / 1000.0).toInt()
    private val primerSamples = (PRIMER_MS * sampleRate / 1000.0).toInt()

    /**
     * Splits [utterance] into one or more chunks.
     * A ≤ 12 s utterance yields exactly one chunk with unchanged bounds.
     */
    fun split(utterance: Utterance): List<InferenceChunk> {
        require(utterance.sampleRate == sampleRate) {
            "utterance rate ${utterance.sampleRate} != configured $sampleRate"
        }
        val n = utterance.samples.size
        if (n == 0) return emptyList()

        val msPerSample = 1000.0 / sampleRate
        if (n <= maxChunkSamples) {
            return listOf(InferenceChunk(utterance.samples, utterance.audioOriginMs))
        }

        val chunks = ArrayList<InferenceChunk>(2)
        var contentStart = 0
        while (contentStart < n) {
            val end = minOf(contentStart + maxChunkSamples, n)
            // Continuations prepend primer from before their nominal start;
            // clamped at 0 so the very first chunk never pretends to be longer.
            val withPrimerStart = if (contentStart == 0) 0 else maxOf(0, contentStart - primerSamples)
            val samples = utterance.samples.copyOfRange(withPrimerStart, end)
            val originMs = utterance.audioOriginMs + withPrimerStart * msPerSample
            chunks += InferenceChunk(samples, originMs)

            if (end == n) break
            contentStart = end
        }
        return chunks
    }
}