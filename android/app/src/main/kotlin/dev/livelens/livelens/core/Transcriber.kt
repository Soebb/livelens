package dev.livelens.livelens.core

/**
 * One decode outcome: the segmented lines plus the model-reported language
 * and a confidence score (F-03: confidences are persisted per segment).
 */
class Transcription(
    val lines: List<String>,
    /** Model-reported language short code, or the requested one when unknown. */
    val lang: String,
    val conf: Double,
)

/**
 * Inference abstraction (B-04). Implementations decode one 16 kHz chunk
 * into per-line source texts. In `task=translate` mode Whisper emits the
 * English rendering directly (target text; HT-3 en-only) — the source-text
 * mirror and the local MT cascade are later work.
 *
 * [task] is `transcribe` or `translate` (F-01/F-02). [language] is an ISO
 * code, or `""` for model-side auto-detect (F-03).
 *
 * Implementations must be thread-confined to the inference executor thread
 * (§3.2 single mutex) and must never throw for ordinary decode failures —
 * return an empty [Transcription] and let the caller report degraded quality.
 */
interface Transcriber {
    /** Synchronous warm-up (model load). Called once before first decode. */
    fun warmUp()

    /**
     * Decodes [chunk] to one text per segment line. May return an empty
     * [Transcription] (silence/hallucination suppression). Blocking;
     * budget-bounded.
     */
    fun decode(chunk: InferenceChunk, task: String, language: String): Transcription

    /** Releases native resources. Idempotent. */
    fun close()
}

/**
 * Placeholder executor used until a model is hot-loaded. Keeps the capture
 * pipeline end-to-end testable and emits honest empty results.
 */
class NoopTranscriber : Transcriber {
    override fun warmUp() = Unit

    override fun decode(
        chunk: InferenceChunk,
        task: String,
        language: String,
    ): Transcription = Transcription(emptyList(), language.ifEmpty { "auto" }, 0.0)

    override fun close() = Unit
}
