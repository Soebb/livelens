package dev.livelens.livelens.core

/**
 * Deterministic caption-line assembler (C-01, architecture §3.3).
 *
 * Golden rules (all unit-tested):
 * - Merge model micro-segments when gap < 240 ms AND combined chars ≤ 84.
 * - A final line replaces on-screen partials immediately upon arrival
 *   (max-dwell rule) — modeled by [onFinal] replacing current line state.
 * - Inter-segment gap > 4 s ⇒ clear screen rather than stale lingering.
 *
 * Pure Kotlin: no Android imports, fully unit-testable (checklist Epic 3).
 */
class SubtitleLineBuilder(
    private val clock: () -> Long = System::currentTimeMillis,
) {
    /** A caption line ready for overlay rendering. */
    data class Line(
        val text: String,
        val t0Ms: Double,
        val t1Ms: Double,
        val segIds: List<String>,
    )

    companion object {
        /** Merge micro-segments closer than this (ms). */
        const val MERGE_GAP_MS = 240.0

        /** Combined line budget in characters (2 × ~42). */
        const val MAX_LINE_CHARS = 84

        /** Screen clears when no segment arrives within this window (ms). */
        const val CLEAR_AFTER_MS = 4_000.0
    }

    private var current: Line? = null
    private var lastArrivalWallMs = 0L

    /** Currently displayed line, or null after a clear. */
    val onScreen: Line? get() = current

    /**
     * Feed one finalized model segment. Returns the resulting on-screen
     * line (merged or replaced), never null.
     *
     * Merge rule: joins with previous line when the inter-segment gap is
     * below [MERGE_GAP_MS] and the combined text fits [MAX_LINE_CHARS].
     * Punctuation-aware: merging is FORCED OFF when the previous line ends
     * with sentence-terminal punctuation (. ! ? 。！？ …) — a finished
     * sentence must not absorb its successor.
     */
    fun onFinal(
        segId: String,
        text: String,
        t0Ms: Double,
        t1Ms: Double,
    ): Line {
        val now = clock()
        lastArrivalWallMs = now

        val prev = current
        val canMerge = prev != null &&
            (t0Ms - prev.t1Ms) < MERGE_GAP_MS &&
            (prev.text.length + 1 + text.length) <= MAX_LINE_CHARS &&
            !endsWithSentenceTerminal(prev.text)

        current = if (canMerge && prev != null) {
            Line(
                text = joinText(prev.text, text),
                t0Ms = prev.t0Ms,
                t1Ms = t1Ms,
                segIds = prev.segIds + segId,
            )
        } else {
            Line(text = text, t0Ms = t0Ms, t1Ms = t1Ms, segIds = listOf(segId))
        }
        return current!!
    }

    /**
     * Advance time-based housekeeping; call periodically from the overlay
     * loop. Clears the screen when the last arrival is older than
     * [CLEAR_AFTER_MS]. Returns true if this call cleared the screen.
     */
    fun tick(): Boolean {
        val cur = current ?: return false
        if (clock() - lastArrivalWallMs > CLEAR_AFTER_MS) {
            clear()
            return true
        }
        return false
    }

    /** Immediate clear (e.g. pause/stop). */
    fun clear() {
        current = null
    }

    private fun endsWithSentenceTerminal(text: String): Boolean =
        text.trimEnd().let { t ->
            t.isNotEmpty() && t.last() in ".!?。！？…"
        }

    private fun joinText(a: String, b: String): String {
        // No space for CJK adjacency; space for latin scripts.
        val needsSpace = a.isNotEmpty() && b.isNotEmpty() &&
            a.last().isLetterOrDigit() && b.first().isLetterOrDigit() &&
            a.last().code < 0x2E80 && b.first().code < 0x2E80
        return if (needsSpace) "$a $b" else a + b
    }
}