package dev.livelens.livelens.core

import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Single-slot inference executor (B-04): one worker thread, bounded work
 * queue, shutdown-drain. Gives the transcriber the thread confinement the
 * sherpa-onnx mutex contract (§3.2) requires and feeds the Governor real
 * queue-depth backpressure metrics.
 *
 * Drop policy when full: drop the NEWEST chunk (offer fails). The oldest
 * queued audio is closest to being spoken now, so keeping it minimizes
 * subtitle lag; the drop is counted for the perf event.
 */
class InferenceExecutor(private val capacity: Int = QUEUE_CAPACITY) {

    private val queue = ArrayBlockingQueue<InferenceChunk>(capacity)
    private var worker: Thread? = null

    @Volatile private var shutdown = false
    @Volatile private var dropped = 0L

    val depth: Int get() = queue.size
    val droppedChunks: Long get() = dropped

    /**
     * Starts the worker. [warmUp] runs once on the worker thread (model
     * hot-load); [decode] runs for every accepted chunk on that same thread.
     */
    fun start(warmUp: () -> Unit, decode: (InferenceChunk) -> Unit) {
        check(worker == null) { "InferenceExecutor already started" }
        shutdown = false
        worker = Thread({
            try {
                warmUp()
            } catch (t: Throwable) {
                // decode failures surface per-chunk; warm-up failure must
                // not kill the thread or the session would go silent.
            }
            while (!shutdown || queue.isNotEmpty()) {
                val chunk = queue.poll(POLL_MS, TimeUnit.MILLISECONDS) ?: continue
                try {
                    decode(chunk)
                } catch (_: Throwable) {
                    // Transcriber contract: decode never throws for ordinary
                    // failures; this is a last-resort guard.
                }
            }
        }, "livelens-inference").apply { isDaemon = true; start() }
    }

    /** Returns false when the queue is full (chunk dropped, [dropped] bumped). */
    fun submit(chunk: InferenceChunk): Boolean {
        if (shutdown) return false
        val ok = queue.offer(chunk)
        if (!ok) dropped++
        return ok
    }

    /**
     * Stops accepting work; the worker finishes everything already queued
     * (bounded by [timeoutMs]) then exits. Idempotent.
     */
    fun shutdownDrain(timeoutMs: Long = DRAIN_TIMEOUT_MS) {
        shutdown = true
        worker?.let { w ->
            w.join(timeoutMs)
            if (w.isAlive) w.interrupt()
        }
        worker = null
        queue.clear()
    }

    companion object {
        /** Bounded queue depth (§3.3): ~2 utterances ≈ 24 s worst case. */
        const val QUEUE_CAPACITY = 2
        const val DRAIN_TIMEOUT_MS = 1_500L
        private const val POLL_MS = 50L
    }
}
