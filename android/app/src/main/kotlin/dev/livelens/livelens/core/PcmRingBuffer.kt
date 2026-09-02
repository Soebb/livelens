package dev.livelens.livelens.core

import java.util.concurrent.atomic.AtomicLong

/**
 * Lock-free-ish PCM16 ring buffer for capture → VAD hand-off (B-01).
 *
 * Single producer / single consumer. Producer never blocks: when full,
 * the OLDEST samples are dropped and [droppedSamples] grows (the
 * backpressure metric the governor watches, §3.2).
 *
 * Capacity is expressed in samples; ≥ 10 s @ 16 kHz per B-01.
 */
class PcmRingBuffer(private val capacitySamples: Int) {

    init {
        require(capacitySamples > 0) { "capacity must be positive" }
    }

    private val buffer = ShortArray(capacitySamples)
    private var readPos = 0
    private var writePos = 0
    private var stored = 0

    /** Total samples dropped due to overflow — governor metric. */
    val droppedSamples = AtomicLong(0)

    /** Samples currently readable. */
    val available: Int get() = stored

    /** Remaining writable space before drop-oldest kicks in. */
    val freeSpace: Int get() = capacitySamples - stored

    /**
     * Writes PCM16 samples. Never blocks; drops oldest on overflow.
     * Returns number of samples actually retained from [data].
     */
    @Synchronized
    fun write(data: ShortArray, offset: Int = 0, length: Int = data.size): Int {
        require(offset >= 0 && length >= 0 && offset + length <= data.size)

        if (length >= capacitySamples) {
            // Whole-chunk overflow: keep only the newest capacity.
            droppedSamples.addAndGet(length - capacitySamples.toLong())
            System.arraycopy(data, offset + length - capacitySamples, buffer, 0, capacitySamples)
            writePos = 0
            readPos = 0
            stored = capacitySamples
            return length
        }

        var overflow = stored + length - capacitySamples
        if (overflow > 0) {
            // Drop oldest `overflow` samples first.
            droppedSamples.addAndGet(overflow.toLong())
            readPos = (readPos + overflow) % capacitySamples
            stored -= overflow
        }

        // Copy possibly-wrapping region.
        var remaining = length
        var srcOff = offset
        while (remaining > 0) {
            val chunk = minOf(remaining, capacitySamples - writePos)
            System.arraycopy(data, srcOff, buffer, writePos, chunk)
            writePos = (writePos + chunk) % capacitySamples
            srcOff += chunk
            remaining -= chunk
        }
        stored += length
        return length
    }

    /**
     * Reads up to [maxSamples] into a new array. Returns null when empty.
     * Consumed samples are removed.
     */
    @Synchronized
    fun read(maxSamples: Int): ShortArray? {
        if (stored == 0) return null
        val n = minOf(maxSamples, stored)
        val out = ShortArray(n)
        var remaining = n
        var dstOff = 0
        while (remaining > 0) {
            val chunk = minOf(remaining, capacitySamples - readPos)
            System.arraycopy(buffer, readPos, out, dstOff, chunk)
            readPos = (readPos + chunk) % capacitySamples
            dstOff += chunk
            remaining -= chunk
        }
        stored -= n
        return out
    }

    /** Peeks without consuming; null when empty. */
    @Synchronized
    fun peek(maxSamples: Int): ShortArray? {
        if (stored == 0) return null
        val n = minOf(maxSamples, stored)
        val out = ShortArray(n)
        var remaining = n
        var dstOff = 0
        var pos = readPos
        while (remaining > 0) {
            val chunk = minOf(remaining, capacitySamples - pos)
            System.arraycopy(buffer, pos, out, dstOff, chunk)
            pos = (pos + chunk) % capacitySamples
            dstOff += chunk
            remaining -= chunk
        }
        return out
    }

    @Synchronized
    fun clear() {
        readPos = 0
        writePos = 0
        stored = 0
    }
}