package dev.livelens.livelens.core

/**
 * Guards against Whisper hallucination loops on music/noise (B-04b,
 * architecture §3.3):
 *
 * 1. Silence skip: "skip inference when VAD speech ratio < 15% AND
 *    duration < 700 ms" — short low-speech blips are noise, not words.
 * 2. Repetition ladder: identical decoded text appearing repeatedly is the
 *    classic Whisper loop signature:
 *      - ≥ 4 consecutive → mark suspicious (still shown, flagged)
 *      - ≥ 8 consecutive → suppress + raise "silent content" hint chip
 *
 * Pure Kotlin, stateful per session; reset on pause/stop.
 */
class HallucinationGuard {

    /** Verdict for a decoded chunk. */
    enum class Verdict {
        /** Emit normally to overlay + storage. */
        EMIT,

        /** Emit but flag suspicious (UI may dim / annotate). */
        EMIT_SUSPICIOUS,

        /** Do not emit; suppress silently and show silent-content chip. */
        SUPPRESS,

        /** Not even decoded — skipped pre-inference by silence rule. */
        SKIP_SILENCE,
    }

    data class Decision(val verdict: Verdict, val repetitionCount: Int = 0)

    /**
     * Pre-inference gate: should this VAD utterance be decoded at all?
     * §3.3: speech ratio < 15% AND duration < 700 ms ⇒ skip.
     */
    fun shouldDecode(speechRatio: Double, durationMs: Double): Boolean =
        !(speechRatio < 0.15 && durationMs < 700.0)

    /**
     * Post-inference gate for finalized text. Tracks consecutive repeats.
     * Call once per final segment in arrival order.
     */
    fun evaluate(text: String): Decision {
        if (text.isBlank()) {
            return Decision(Verdict.SUPPRESS)
        }

        if (text == lastText) {
            consecutive++
        } else {
            lastText = text
            consecutive = 1
        }

        return when {
            consecutive >= SUPPRESS_AFTER ->
                Decision(Verdict.SUPPRESS, consecutive)
            consecutive >= SUSPICIOUS_AFTER ->
                Decision(Verdict.EMIT_SUSPICIOUS, consecutive)
            else -> Decision(Verdict.EMIT, consecutive)
        }
    }

    /**
     * Whether the "silent content" hint chip should currently be raised
     * (i.e., we are actively suppressing a loop).
     */
    fun isSilentContentHintActive(): Boolean = consecutive >= SUPPRESS_AFTER

    /** Reset on pause/resume/stop/session boundaries. */
    fun reset() {
        lastText = null
        consecutive = 0
    }

    private var lastText: String? = null
    private var consecutive = 0

    companion object {
        const val SUSPICIOUS_AFTER = 4
        const val SUPPRESS_AFTER = 8

        /**
         * Whisper loop signature inside ONE decode result: the same sentence
         * echoed 2+ times ("I feel like I'm… I feel like I'm…"). Keeps the
         * first occurrence of each sentence unit, drops exact repeats.
         *
         * Splits on sentence terminators (both Latin and CJK) plus newlines;
         * whitespace-only fragments are preserved as-is. Pure function.
         */
        fun collapseIntraRepetition(text: String): String {
            if (text.isBlank()) return text
            // Sentence units with their trailing terminator, e.g.
            // "I feel like… " "I feel like… " → "I feel like… "
            val units = Regex("(.*?[.!?。？！…]+[\\s]*)|(.+$)")
                .findAll(text)
                .map { it.value }
                .filter { it.isNotBlank() }
                .toList()
            if (units.size <= 1) return text
            val seen = HashSet<String>()
            val kept = ArrayList<String>(units.size)
            for (unit in units) {
                // Compare on trimmed content so "Hi. " and "Hi." match.
                if (!seen.add(unit.trim())) continue
                kept += unit
            }
            return kept.joinToString("").trim()
        }
    }
}