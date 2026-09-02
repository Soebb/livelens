package dev.livelens.livelens.core

/**
 * Adaptive degradation policy engine (B-07).
 *
 * Architecture §3.2: "All degradation policy in ONE place (thermal,
 * battery, RTF, queue depth) — testable independently."
 *
 * Decision table (evaluated top-down, highest severity wins):
 * ┌────────────────────────┬──────────────────────────────────────────┐
 * │ Condition              │ Action                                   │
 * ├────────────────────────┼──────────────────────────────────────────┤
 * │ thermal SEVERE         │ PAUSE_THERMAL (latched)                  │
 * │ thermal normal ≥       │ RESUME_FROM_THERMAL                      │
 * │   hysteresisMs         │                                          │
 * │ battery ≤ lowThreshold │ PAUSE_BATTERY (latched until recharged)  │
 * │ overload (queue >75%   │ DOWNGRADE_MODEL if possible, else        │
 * │   AND rtf over limit)  │ PAUSE_OVERLOAD                           │
 * │ strain (queue >75% OR  │ SHORTEN_WINDOW                           │
 * │   rtf over limit)      │                                          │
 * │ screen off + pref      │ PAUSE_SCREEN_OFF                         │
 * │ otherwise              │ NONE                                     │
 * └────────────────────────┴──────────────────────────────────────────┘
 *
 * Pure Kotlin; listeners (PowerManager/BatteryManager) feed [Metrics] from
 * the service layer. Injectable clock makes hysteresis deterministic.
 */
class Governor(
    private val prefs: Prefs = Prefs(),
    private val clock: () -> Long = System::currentTimeMillis,
) {
    /** User-tunable governor preferences (contract §2.2 setGovernorPrefs). */
    data class Prefs(
        val screenOffAutoPause: Boolean = false,
        val batteryLowThresholdPct: Int = 15,
        val thermalHysteresisMs: Long = 60_000,
        /** RTF ceiling before "strain" is declared (flagship ≈ 0.6 budget). */
        val rtfStrainLimit: Double = 0.8,
    )

    /** Snapshot of all governor inputs at evaluation time. */
    data class Metrics(
        val rtf: Double,
        val queueDepth: Int,
        val queueCapacity: Int,
        val thermalLevel: ThermalLevel = ThermalLevel.NONE,
        val batteryPct: Double = 100.0,
        val screenOn: Boolean = true,
    ) {
        val queueOccupancy: Double
            get() = if (queueCapacity <= 0) 0.0 else queueDepth.toDouble() / queueCapacity
    }

    enum class ThermalLevel { NONE, MODERATE, SEVERE }

    enum class Action {
        NONE,
        SHORTEN_WINDOW,
        DOWNGRADE_MODEL,
        PAUSE_THERMAL,
        RESUME_FROM_THERMAL,
        PAUSE_BATTERY,
        PAUSE_OVERLOAD,
        PAUSE_SCREEN_OFF,
    }

    data class Decision(val action: Action, val reason: String)

    // Latched state -----------------------------------------------------------

    private var thermallyPaused = false
    private var lastSevereAtMs = Long.MIN_VALUE
    private var batteryPaused = false
    private var downgraded = false

    /** True while a thermal pause is active (drives the 🌡 chip). */
    val isThermallyPaused: Boolean get() = thermallyPaused

    /** True while a battery pause is active (drives the 🔋 chip). */
    val isBatteryPaused: Boolean get() = batteryPaused

    /** Whether the hot model has been downgraded this session. */
    val hasDowngradedModel: Boolean get() = downgraded

    /**
     * Evaluate one metrics snapshot. Call whenever any input changes or
     * periodically (~1 Hz); idempotent for unchanged inputs.
     *
     * @param canDowngradeModel whether a smaller installed model exists
     */
    fun evaluate(m: Metrics, canDowngradeModel: Boolean = false): Decision {
        // --- thermal (hysteresis-gated) -------------------------------------
        if (m.thermalLevel == ThermalLevel.SEVERE) {
            lastSevereAtMs = clock()
            if (!thermallyPaused) {
                thermallyPaused = true
                return Decision(Action.PAUSE_THERMAL, "thermal SEVERE")
            }
        } else if (thermallyPaused && m.thermalLevel == ThermalLevel.NONE) {
            val sinceSevere = clock() - lastSevereAtMs
            if (lastSevereAtMs != Long.MIN_VALUE && sinceSevere >= prefs.thermalHysteresisMs) {
                thermallyPaused = false
                return Decision(Action.RESUME_FROM_THERMAL, "thermal normal ${sinceSevere}ms")
            }
            return Decision(Action.NONE, "thermal cooling (hysteresis)")
        }

        // While a thermal pause is latched, no other policy may act — the
        // device is cooling; resuming capture would re-trigger SEVERE.
        if (thermallyPaused) {
            return Decision(Action.NONE, "thermal pause latched")
        }

        // --- battery (latched until above threshold again) -------------------
        if (!batteryPaused && m.batteryPct <= prefs.batteryLowThresholdPct) {
            batteryPaused = true
            return Decision(Action.PAUSE_BATTERY, "battery ${m.batteryPct}%")
        } else if (batteryPaused && m.batteryPct > prefs.batteryLowThresholdPct) {
            batteryPaused = false // auto-recover on charge; no separate action
        }

        // --- overload / strain ------------------------------------------------
        val overloaded = m.queueOccupancy > OVERLOAD_OCCUPANCY &&
            m.rtf > prefs.rtfStrainLimit
        val strained = m.queueOccupancy > OVERLOAD_OCCUPANCY ||
            m.rtf > prefs.rtfStrainLimit

        if (overloaded) {
            return if (!downgraded && canDowngradeModel) {
                downgraded = true
                Decision(Action.DOWNGRADE_MODEL, "occ=${"%.2f".format(m.queueOccupancy)} rtf=${m.rtf}")
            } else {
                Decision(Action.PAUSE_OVERLOAD, "no downgrade left")
            }
        }
        if (strained) {
            return Decision(Action.SHORTEN_WINDOW, "occ=${"%.2f".format(m.queueOccupancy)} rtf=${m.rtf}")
        }

        // --- screen-off preference --------------------------------------------
        if (!m.screenOn && prefs.screenOffAutoPause) {
            return Decision(Action.PAUSE_SCREEN_OFF, "screen off + pref")
        }

        return Decision(Action.NONE, "healthy")
    }

    companion object {
        /** §3.2: "governor reacts when >75% occupancy". */
        const val OVERLOAD_OCCUPANCY = 0.75
    }
}