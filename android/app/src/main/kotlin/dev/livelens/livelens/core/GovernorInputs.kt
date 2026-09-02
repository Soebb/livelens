package dev.livelens.livelens.core

/**
 * Pure helpers feeding real-world inputs into the Governor (§3.7 rows 2–3,
 * 5). No Android imports — the service layer translates hardware callbacks
 * into ints/time so every rule here is unit-testable.
 */
object ThermalLevels {
    /** PowerManager.THERMAL_STATUS_* → Governor.ThermalLevel. */
    fun fromStatus(status: Int): Governor.ThermalLevel = when {
        status >= SEVERE_STATUS -> Governor.ThermalLevel.SEVERE
        status >= MODERATE_STATUS -> Governor.ThermalLevel.MODERATE
        else -> Governor.ThermalLevel.NONE
    }

    /** PowerManager.THERMAL_STATUS_MODERATE (unused by policy, kept honest). */
    const val MODERATE_STATUS = 2

    /** PowerManager.THERMAL_STATUS_SEVERE — the §3.7 pause threshold. */
    const val SEVERE_STATUS = 3
}

/**
 * §3.7 "Silence forever" guard: after [thresholdMs] without a single
 * recognized utterance, [shouldHint] fires exactly once (the persistent
 * notification is quietly updated to a "Still listening?" nudge — no
 * spam, no zombie battery drain). Re-armed by the next utterance.
 */
class SilenceWatch(
    private val thresholdMs: Long = SILENCE_HINT_MS,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private var lastSpeechAtMs: Long = clock()
    private var hintShown = false

    fun onSpeech() {
        lastSpeechAtMs = clock()
        hintShown = false
    }

    /** New session: re-arm the window from now. */
    fun reset() {
        lastSpeechAtMs = clock()
        hintShown = false
    }

    fun silentForMs(): Long = clock() - lastSpeechAtMs

    fun shouldHint(): Boolean =
        !hintShown && silentForMs() >= thresholdMs && markHinted()

    private fun markHinted(): Boolean {
        // cheap single-shot guard; tick callers are single-threaded
        if (hintShown) return false
        hintShown = true
        return true
    }

    companion object {
        /** §3.7: no speech > 10 min ⇒ quiet hint. */
        const val SILENCE_HINT_MS = 10L * 60 * 1000
    }
}
