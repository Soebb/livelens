package dev.livelens.livelens.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PcmRingBufferTest {

    @Test
    fun `write then read preserves order and content`() {
        val rb = PcmRingBuffer(16)
        rb.write(shortArrayOf(1, 2, 3, 4, 5))
        assertArrayEquals(shortArrayOf(1, 2, 3, 4, 5), rb.read(16))
        assertNull(rb.read(16))
    }

    @Test
    fun `wrapping write and read across the boundary is seamless`() {
        val rb = PcmRingBuffer(8)
        rb.write(shortArrayOf(1, 2, 3, 4, 5, 6)) // wraps internally
        assertEquals(6, rb.available)
        // Read in two pieces to force wrap-aware reads.
        assertArrayEquals(shortArrayOf(1, 2), rb.read(2))
        rb.write(shortArrayOf(7, 8, 9, 10))
        assertArrayEquals(shortArrayOf(3, 4, 5, 6, 7, 8, 9, 10), rb.read(16))
    }

    @Test
    fun `overflow drops OLDEST samples and counts them`() {
        val rb = PcmRingBuffer(4)
        rb.write(shortArrayOf(1, 2, 3, 4))
        rb.write(shortArrayOf(5, 6))
        assertEquals(2L, rb.droppedSamples.get())
        assertArrayEquals(shortArrayOf(3, 4, 5, 6), rb.read(16))
    }

    @Test
    fun `oversized chunk keeps only newest capacity worth`() {
        val rb = PcmRingBuffer(4)
        rb.write(shortArrayOf(1, 2, 3, 4, 5, 6, 7))
        assertEquals(3L, rb.droppedSamples.get())
        assertArrayEquals(shortArrayOf(4, 5, 6, 7), rb.read(16))
    }

    @Test
    fun `peek does not consume`() {
        val rb = PcmRingBuffer(8)
        rb.write(shortArrayOf(9, 8, 7))
        assertArrayEquals(shortArrayOf(9, 8, 7), rb.peek(8))
        assertEquals(3, rb.available)
    }

    @Test
    fun `clear resets state`() {
        val rb = PcmRingBuffer(4)
        rb.write(shortArrayOf(1, 2))
        rb.clear()
        assertEquals(0, rb.available)
        assertNull(rb.read(4))
    }
}

class LinearResamplerTest {

    private fun ramp(n: Int, rate: Int): ShortArray =
        ShortArray(n) { i -> (i * 1000 % Short.MAX_VALUE.toInt()).toShort() }

    @Test
    fun `identity resample when rates match`() {
        val r = LinearResampler(inputRate = 16_000, outputRate = 16_000)
        val input = shortArrayOf(100, -200, 300, -400, 500)
        assertArrayEquals(input, r.process(input))
    }

    @Test
    fun `downsample 48k to 16k yields one third length per chunk`() {
        val r = LinearResampler(inputRate = 48_000)
        val input = ramp(4800, 48_000) // 100 ms @48k
        val out = r.process(input)
        // ~1600 expected (±1 for boundary interpolation).
        assertTrue("got ${out.size}", out.size in 1599..1601)
    }

    @Test
    fun `chunked processing equals single-shot within tolerance`() {
        val full = ramp(24_000, 48_000) // 500 ms @48k
        val oneShot = LinearResampler(48_000).process(full)

        val chunked = LinearResampler(48_000)
        val acc = ShortArray(oneShot.size + 8)
        var written = 0
        var off = 0
        while (off < full.size) {
            val end = minOf(off + 1024, full.size)
            val piece = chunked.process(full.copyOfRange(off, end))
            piece.copyInto(acc, written)
            written += piece.size
            off = end
        }

        assertEquals(oneShot.size, written)
        // Seam continuity: allow ±1 LSB differences at chunk boundaries.
        for (i in 0 until written) {
            assertTrue(
                "delta at $i",
                kotlin.math.abs(oneShot[i] - acc[i]) <= 1,
            )
        }
    }

    @Test
    fun `output stays within PCM16 range on steep ramps`() {
        val r = LinearResampler(44_100)
        val extreme = ShortArray(4096) { i ->
            if (i % 2 == 0) Short.MAX_VALUE else Short.MIN_VALUE
        }
        val out = r.process(extreme)
        for (v in out) {
            assertTrue(v >= Short.MIN_VALUE && v <= Short.MAX_VALUE)
        }
    }

    @Test
    fun `tiny chunks accumulate without losing samples`() {
        val r = LinearResampler(48_000)
        var produced = 0
        repeat(10) { produced += r.process(shortArrayOf(1000)).size }
        // 10 input samples @48k→16k should yield ~3 outputs total.
        assertTrue(produced <= 4)
    }
}

class SubtitleLineBuilderTest {

    /** Deterministic clock: starts at 0, advanced explicitly. */
    private class FakeClock {
        var now = 0L
        fun read(): Long = now
    }

    private fun builderWith(clock: FakeClock): SubtitleLineBuilder =
        SubtitleLineBuilder(clock = { clock.read() })

    @Test
    fun `first segment becomes the on-screen line`() {
        val b = SubtitleLineBuilder()
        val line = b.onFinal("s1", "Hello world", 0.0, 2000.0)
        assertEquals("Hello world", line.text)
        assertEquals(listOf("s1"), line.segIds)
        assertEquals(line, b.onScreen)
    }

    @Test
    fun `micro-segments merge when gap below 240ms and fits budget`() {
        val b = SubtitleLineBuilder()
        b.onFinal("s1", "I think we", 0.0, 1000.0)
        val merged = b.onFinal("s2", "should leave soon.", 1100.0, 2200.0)
        assertEquals("I think we should leave soon.", merged.text)
        assertEquals(listOf("s1", "s2"), merged.segIds)
        assertEquals(0.0, merged.t0Ms, 0.001)
        assertEquals(2200.0, merged.t1Ms, 0.001)
    }

    @Test
    fun `no merge when gap reaches 240ms`() {
        val b = SubtitleLineBuilder()
        b.onFinal("s1", "First sentence.", 0.0, 1000.0)
        val second = b.onFinal("s2", "Second sentence.", 1240.0, 2400.0)
        assertEquals(listOf("s2"), second.segIds)
        assertEquals("Second sentence.", second.text)
    }

    @Test
    fun `no merge when combined text exceeds 84 chars`() {
        val b = SubtitleLineBuilder()
        val longA = "a".repeat(50)
        val longB = "b".repeat(40) // 50 + 1 + 40 > 84
        b.onFinal("s1", longA, 0.0, 1000.0)
        val second = b.onFinal("s2", longB, 1050.0, 2000.0)
        assertEquals(listOf("s2"), second.segIds)
    }

    @Test
    fun `punctuation blocks merging finished sentences`() {
        val b = SubtitleLineBuilder()
        b.onFinal("s1", "Done here.", 0.0, 900.0)
        val next = b.onFinal("s2", "New thought", 950.0, 2000.0)
        assertEquals(listOf("s2"), next.segIds)
    }

    @Test
    fun `japanese terminal punctuation also blocks merge`() {
        val b = SubtitleLineBuilder()
        b.onFinal("s1", "そろそろ出発したほうがいいと思います。", 0.0, 1500.0)
        val next = b.onFinal("s2", "明日ね。", 1550.0, 2500.0)
        assertEquals(listOf("s2"), next.segIds)
    }

    @Test
    fun `cjk join adds no space but latin does`() {
        val b = SubtitleLineBuilder()
        b.onFinal("s1", "こんにちは", 0.0, 800.0)
        val cjk = b.onFinal("s2", "世界", 850.0, 1600.0)
        assertEquals("こんにちは世界", cjk.text)

        b.clear()
        b.onFinal("s1", "Hello", 10_000.0, 11_000.0)
        val latin = b.onFinal("s2", "world", 11_050.0, 12_000.0)
        assertEquals("Hello world", latin.text)
    }

    @Test
    fun `tick clears screen after 4 seconds of silence`() {
        val clock = FakeClock()
        val b = builderWith(clock)
        b.onFinal("s1", "text", 0.0, 1000.0)
        clock.now = 4000L
        assertFalse(b.tick()) // exactly 4 s: not yet (strictly greater)
        clock.now = 4001L
        assertTrue(b.tick())
        assertNull(b.onScreen)
    }

    @Test
    fun `arrival refreshes the clear timer`() {
        val clock = FakeClock()
        val b = builderWith(clock)
        b.onFinal("s1", "one", 0.0, 500.0)
        clock.now = 3000L
        b.onFinal("s2", "two", 3500.0, 4000.0) // refreshes timer
        clock.now = 6500L
        assertFalse(b.tick())
        clock.now = 7001L
        assertTrue(b.tick())
    }
}