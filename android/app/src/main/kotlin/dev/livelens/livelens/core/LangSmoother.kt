package dev.livelens.livelens.core

/**
 * Auto-detect guardrail (PRD F-03).
 *
 * Whisper reports a per-utterance detected language; raw detections flip
 * between neighboring languages on short or noisy speech. This smoother
 * applies the documented policy:
 *
 *  - utterances shorter than 1.5 s reuse the prior majority vote;
 *  - otherwise the detection joins a majority-vote window (last 5
 *    confident utterances);
 *  - when the window is empty, falls back to the last confident language;
 *  - a forced source language always wins (F-01 "force source").
 */
class LangSmoother(
    private val windowSize: Int = 5,
    private val minConfidentMs: Long = 1_500,
) {

    private val recent = ArrayDeque<String>()
    private var lastConfident = ""

    /**
     * Resolves the language to tag a segment with.
     *
     * @param utteranceMs audio length of the utterance
     * @param detected model-reported language (""/"auto" when unknown)
     * @param forced user-selected source language, or null for Auto
     */
    fun resolve(utteranceMs: Long, detected: String, forced: String?): String {
        forced?.let { return it }

        if (utteranceMs < minConfidentMs) {
            // Short utterance: reuse prior vote (F-03), don't poison the window.
            return majority()
        }

        val det = detected.trim().lowercase()
        if (det.isNotEmpty() && det != "auto") {
            recent.addLast(det)
            while (recent.size > windowSize) recent.removeFirst()
            lastConfident = det
        }
        return majority()
    }

    private fun majority(): String {
        if (recent.isEmpty()) return lastConfident.ifEmpty { "auto" }
        val counts = recent.groupingBy { it }.eachCount()
        // maxByOrNull keeps the FIRST maximal entry on ties — i.e. the older
        // language wins ties, which damps flip-flopping at window edges.
        return counts.maxByOrNull { it.value }!!.key
    }

    /** Clears state (new session). */
    fun reset() {
        recent.clear()
        lastConfident = ""
    }
}
