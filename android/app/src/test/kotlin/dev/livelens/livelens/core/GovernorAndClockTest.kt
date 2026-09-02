package dev.livelens.livelens.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GovernorTest {

    /** Deterministic clock for hysteresis testing. */
    private class FakeClock {
        var now = 0L
    }

    private fun governor(clock: FakeClock, prefs: Governor.Prefs = Governor.Prefs()) =
        Governor(prefs = prefs, clock = { clock.now })

    private fun healthy(
        rtf: Double = 0.3,
        queueDepth: Int = 0,
        queueCapacity: Int = 3,
        thermal: Governor.ThermalLevel = Governor.ThermalLevel.NONE,
        batteryPct: Double = 100.0,
        screenOn: Boolean = true,
    ) = Governor.Metrics(
        rtf = rtf,
        queueDepth = queueDepth,
        queueCapacity = queueCapacity,
        thermalLevel = thermal,
        batteryPct = batteryPct,
        screenOn = screenOn,
    )

    @Test
    fun `healthy metrics yield NONE`() {
        val g = Governor()
        assertEquals(Governor.Action.NONE, g.evaluate(healthy()).action)
        assertFalse(g.isThermallyPaused)
        assertFalse(g.isBatteryPaused)
    }

    @Test
    fun `severe thermal latches pause and hysteresis gates resume`() {
        val clock = FakeClock()
        val g = governor(clock, Governor.Prefs(thermalHysteresisMs = 60_000))

        // First severe → pause.
        var d = g.evaluate(healthy(thermal = Governor.ThermalLevel.SEVERE))
        assertEquals(Governor.Action.PAUSE_THERMAL, d.action)
        assertTrue(g.isThermallyPaused)

        // Still severe → stays paused, no duplicate action (idempotent).
        d = g.evaluate(healthy(thermal = Governor.ThermalLevel.SEVERE))
        assertEquals(Governor.Action.NONE, d.action)
        assertTrue(g.isThermallyPaused)

        // Back to normal but BEFORE hysteresis → no resume yet.
        clock.now = 30_000
        d = g.evaluate(healthy())
        assertEquals(Governor.Action.NONE, d.action)
        assertTrue(g.isThermallyPaused)

        // After hysteresis → resume.
        clock.now = 60_001
        d = g.evaluate(healthy())
        assertEquals(Governor.Action.RESUME_FROM_THERMAL, d.action)
        assertFalse(g.isThermallyPaused)
    }

    @Test
    fun `moderate thermal neither pauses nor blocks other policies`() {
        val g = Governor()
        val d = g.evaluate(
            healthy(rtf = 0.9, thermal = Governor.ThermalLevel.MODERATE),
        )
        assertEquals(Governor.Action.SHORTEN_WINDOW, d.action)
    }

    @Test
    fun `low battery pauses once then auto-recovers on charge`() {
        val g = Governor()
        var d = g.evaluate(healthy(batteryPct = 10.0))
        assertEquals(Governor.Action.PAUSE_BATTERY, d.action)
        assertTrue(g.isBatteryPaused)

        // Still low → no duplicate action (latched).
        d = g.evaluate(healthy(batteryPct = 10.0))
        assertEquals(Governor.Action.NONE, d.action)

        // Charged above threshold → latch clears silently.
        d = g.evaluate(healthy(batteryPct = 40.0))
        assertEquals(Governor.Action.NONE, d.action)
        assertFalse(g.isBatteryPaused)
    }

    @Test
    fun `overload downgrades first then pauses when no downgrade left`() {
        val g = Governor()
        val m = healthy(rtf = 1.2, queueDepth = 3, queueCapacity = 4) // occ .75? >75% needs depth>3

        // Force occupancy above threshold.
        val over = m.copy(queueDepth = 4, queueCapacity = 5) // 80%
        var d = g.evaluate(over, canDowngradeModel = true)
        assertEquals(Governor.Action.DOWNGRADE_MODEL, d.action)
        assertTrue(g.hasDowngradedModel)

        // Next overload with no downgrade available → pause.
        d = g.evaluate(over, canDowngradeModel = true)
        assertEquals(Governor.Action.PAUSE_OVERLOAD, d.action)
    }

    @Test
    fun `strain without overload shortens window`() {
        val g = Governor()
        // RTF over limit alone (queue empty) = strain, not overload.
        val d = g.evaluate(healthy(rtf = 0.95), canDowngradeModel = false)
        assertEquals(Governor.Action.SHORTEN_WINDOW, d.action)
    }

    @Test
    fun `screen-off pref pauses only when enabled and screen off`() {
        val prefs = Governor.Prefs(screenOffAutoPause = true)
        val g = Governor(prefs = prefs)
        assertEquals(
            Governor.Action.PAUSE_SCREEN_OFF,
            g.evaluate(healthy(screenOn = false)).action,
        )
        assertEquals(Governor.Action.NONE, g.evaluate(healthy(screenOn = true)).action)

        val gNoPref = Governor()
        assertEquals(Governor.Action.NONE, gNoPref.evaluate(healthy(screenOn = false)).action)
    }

    @Test
    fun `thermal severity outranks battery and strain`() {
        val clock = FakeClock()
        val g = governor(clock)
        val d = g.evaluate(
            healthy(
                rtf = 1.5,
                queueDepth = 10,
                queueCapacity = 10,
                thermal = Governor.ThermalLevel.SEVERE,
                batteryPct = 5.0,
            ),
        )
        assertEquals(Governor.Action.PAUSE_THERMAL, d.action)
    }
}

class SessionClockTest {

    private class FakeClock {
        var now = 0L
    }

    @Test
    fun `elapsed excludes paused spans`() {
        val c = FakeClock()
        val k = SessionClock { c.now }

        k.start() // t=0
        c.now = 10_000 // 10 s live
        assertEquals(10_000, k.elapsedLiveMs())

        k.pause() // t=10s
        c.now = 15_000 // 5 s paused — must not count
        assertEquals(10_000, k.elapsedLiveMs())

        k.resume() // t=15s
        c.now = 20_000 // +5 s live again
        assertEquals(15_000, k.elapsedLiveMs())

        assertEquals(15_000, k.stop())
    }

    @Test
    fun `multiple pause cycles accumulate correctly`() {
        val c = FakeClock()
        val k = SessionClock { c.now }
        k.start()

        c.now = 5_000; k.pause()
        c.now = 7_000; k.resume() // excluded 2s
        c.now = 12_000; k.pause()
        c.now = 14_000; k.resume() // excluded 2s
        c.now = 17_000

        assertEquals(13_000, k.elapsedLiveMs()) // 17 - 4 paused
    }

    @Test
    fun `stop while paused ends at the pause point`() {
        val c = FakeClock()
        val k = SessionClock { c.now }
        k.start()
        c.now = 8_000
        k.pause()
        c.now = 99_000 // user never resumed; wall time passed
        assertEquals(8_000, k.stop())
        assertFalse(k.isRunning)
    }

    @Test
    fun `pause and resume are idempotent`() {
        val c = FakeClock()
        val k = SessionClock { c.now }
        k.start()
        c.now = 1_000
        k.pause(); k.pause(); k.pause()
        c.now = 2_000
        k.resume(); k.resume()
        c.now = 3_000
        assertEquals(2_000, k.elapsedLiveMs()) // only one pause span excluded
    }

    @Test
    fun `start on running session is a no-op`() {
        val c = FakeClock()
        val k = SessionClock { c.now }
        k.start()
        c.now = 4_000
        k.start() // must NOT reset startedAt
        c.now = 6_000
        assertEquals(6_000, k.elapsedLiveMs())
    }

    @Test
    fun `stop before start returns zero`() {
        assertEquals(0, SessionClock().stop())
    }

    @Test
    fun `state flags track lifecycle`() {
        val c = FakeClock()
        val k = SessionClock { c.now }
        assertFalse(k.isRunning)
        k.start()
        assertTrue(k.isRunning)
        assertFalse(k.isPaused)
        k.pause()
        assertTrue(k.isPaused)
        k.resume()
        assertFalse(k.isPaused)
        k.stop()
        assertFalse(k.isRunning)
    }
}