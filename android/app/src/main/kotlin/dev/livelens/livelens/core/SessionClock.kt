package dev.livelens.livelens.core

/**
 * Session duration clock that EXCLUDES paused spans (B-08).
 *
 * §3.3/B-08: "session clock accounting excludes pause." The notification's
 * elapsed time and `durationMsLive` in storage both read from here, so a
 * 30-min session with 5 min paused reports 25 min.
 *
 * Model: [accumulatedMs] holds all live time from completed segments;
 * [segmentStartMs] is the start of the current live segment (or MIN when
 * paused/stopped). Pause closes the current segment; resume opens a new
 * one. Injectable clock; pure Kotlin.
 */
class SessionClock(private val clock: () -> Long = System::currentTimeMillis) {

    private var accumulatedMs = 0L
    private var segmentStartMs = Long.MIN_VALUE
    private var running = false

    /** Start the session. Re-starting a running session is a no-op. */
    fun start() {
        if (running) return
        segmentStartMs = clock()
        running = true
    }

    /**
     * Pause: close the current live segment. Idempotent — pausing an
     * already-paused or stopped session is a no-op (crash-safety relies on
     * it).
     */
    fun pause() {
        if (!running || segmentStartMs == Long.MIN_VALUE) return
        accumulatedMs += clock() - segmentStartMs
        segmentStartMs = Long.MIN_VALUE
    }

    /** Resume: open a new live segment. Idempotent. */
    fun resume() {
        if (!running || segmentStartMs != Long.MIN_VALUE) return
        segmentStartMs = clock()
    }

    /** Stop and return the final live duration (pauses excluded). */
    fun stop(): Long {
        if (!running) return accumulatedMs
        if (segmentStartMs != Long.MIN_VALUE) {
            accumulatedMs += clock() - segmentStartMs
        }
        running = false
        segmentStartMs = Long.MIN_VALUE
        return accumulatedMs
    }

    /**
     * Current live duration without stopping. While paused, time is frozen
     * at the pause point.
     */
    fun elapsedLiveMs(): Long {
        if (!running) return accumulatedMs
        if (segmentStartMs == Long.MIN_VALUE) return accumulatedMs // paused
        return accumulatedMs + (clock() - segmentStartMs)
    }

    val isRunning: Boolean get() = running
    val isPaused: Boolean get() = running && segmentStartMs == Long.MIN_VALUE
}