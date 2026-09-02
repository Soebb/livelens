package dev.livelens.livelens.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UtteranceSplitterTest {

    private val splitter = UtteranceSplitter(sampleRate = 16_000)

    private fun utteranceOfMs(ms: Double, originMs: Double = 0.0): Utterance {
        val n = (ms * 16_000 / 1000.0).toInt()
        return Utterance(ShortArray(n) { it.toShort() }, 16_000, originMs)
    }

    @Test
    fun `short utterance passes through as single chunk`() {
        val u = utteranceOfMs(5_000.0, originMs = 1_000.0)
        val chunks = splitter.split(u)

        assertEquals(1, chunks.size)
        assertEquals(u.samples, chunks[0].samples)
        assertEquals(1_000.0, chunks[0].originMs, 0.001)
    }

    @Test
    fun `empty utterance yields no chunks`() {
        assertTrue(splitter.split(Utterance(ShortArray(0), 16_000, 0.0)).isEmpty())
    }

    @Test
    fun `25s utterance splits into four chunks`() {
        val u = utteranceOfMs(25_000.0, originMs = 500.0)
        val chunks = splitter.split(u)

        // 8s × 3 + 1s content spans.
        assertEquals(4, chunks.size)
        // First chunk: full 8 s of content, no primer.
        assertEquals(8_000 * 16, chunks[0].samples.size) // ms→samples @16k
        assertEquals(500.0, chunks[0].originMs, 0.001)
        // Second chunk: 320ms primer + 8s content.
        assertEquals((8_000 + 320) * 16, chunks[1].samples.size)
        assertEquals(500.0 + 8_000.0 - 320.0, chunks[1].originMs, 0.001)
        // Fourth chunk: primer + remaining 1 s.
        assertEquals((1_000 + 320) * 16, chunks[3].samples.size)
        assertEquals(500.0 + 24_000.0 - 320.0, chunks[3].originMs, 0.001)
    }

    @Test
    fun `chunk origins are monotonic and cover the span`() {
        val u = utteranceOfMs(30_000.0, originMs = 0.0)
        val chunks = splitter.split(u)
        for (i in 1 until chunks.size) {
            assertTrue(chunks[i].originMs > chunks[i - 1].originMs)
        }
        // Last chunk must reach the end of the utterance.
        val last = chunks.last()
        val lastEnd = last.originMs + last.samples.size / 16.0
        assertEquals(30_000.0, lastEnd, 1.0)
    }

    @Test
    fun `rate mismatch is rejected`() {
        try {
            splitter.split(Utterance(ShortArray(8), 48_000, 0.0))
            assertFalse("expected IllegalArgumentException", true)
        } catch (_: IllegalArgumentException) {
            // expected
        }
    }
}

class HallucinationGuardTest {

    private val guard = HallucinationGuard()

    @Test
    fun `short low-speech blip is skipped pre-inference`() {
        assertFalse(guard.shouldDecode(speechRatio = 0.10, durationMs = 500.0))
    }

    @Test
    fun `short but speechy blip decodes`() {
        assertTrue(guard.shouldDecode(speechRatio = 0.60, durationMs = 500.0))
    }

    @Test
    fun `long low-speech audio still decodes (only AND-rule skips)`() {
        assertTrue(guard.shouldDecode(speechRatio = 0.10, durationMs = 2_000.0))
    }

    @Test
    fun `repetition ladder emits then flags then suppresses`() {
        var d = guard.evaluate("hello")
        assertEquals(HallucinationGuard.Verdict.EMIT, d.verdict)

        repeat(3) { d = guard.evaluate("hello") } // total 4
        assertEquals(HallucinationGuard.Verdict.EMIT_SUSPICIOUS, d.verdict)
        assertEquals(4, d.repetitionCount)

        repeat(3) { d = guard.evaluate("hello") } // total 7
        assertEquals(HallucinationGuard.Verdict.EMIT_SUSPICIOUS, d.verdict)

        d = guard.evaluate("hello") // total 8
        assertEquals(HallucinationGuard.Verdict.SUPPRESS, d.verdict)
        assertTrue(guard.isSilentContentHintActive())
    }

    @Test
    fun `new text resets the ladder`() {
        repeat(6) { guard.evaluate("loop") }
        val d = guard.evaluate("fresh text")
        assertEquals(HallucinationGuard.Verdict.EMIT, d.verdict)
        assertEquals(1, d.repetitionCount)
    }

    @Test
    fun `blank text suppresses without touching ladder`() {
        assertEquals(HallucinationGuard.Verdict.SUPPRESS, guard.evaluate("   ").verdict)
        assertEquals(HallucinationGuard.Verdict.EMIT, guard.evaluate("word").verdict)
    }

    @Test
    fun `reset clears state`() {
        repeat(9) { guard.evaluate("loop") }
        guard.reset()
        assertFalse(guard.isSilentContentHintActive())
        assertEquals(HallucinationGuard.Verdict.EMIT, guard.evaluate("loop").verdict)
    }

    @Test
    fun `intra-chunk repeated sentences collapse to first occurrence`() {
        val text = "I feel like I'm in a real relationship. " +
            "I feel like I'm in a real relationship. " +
            "I feel like I'm in a real relationship."
        assertEquals(
            "I feel like I'm in a real relationship.",
            HallucinationGuard.collapseIntraRepetition(text),
        )
    }

    @Test
    fun `distinct sentences are preserved by intra-collapse`() {
        val text = "Hello there. How are you? I'm fine."
        assertEquals(text, HallucinationGuard.collapseIntraRepetition(text))
    }

    @Test
    fun `intra-collapse handles CJK terminators and no-terminator tails`() {
        // CJK sentence repeated, then a trailing fragment without terminator.
        val text = "ありがとう。ありがとう。ご視聴ありがとうございました"
        assertEquals(
            "ありがとう。ご視聴ありがとうございました",
            HallucinationGuard.collapseIntraRepetition(text),
        )
    }

    @Test
    fun `intra-collapse passes through single-sentence and blank text`() {
        assertEquals("One line only", HallucinationGuard.collapseIntraRepetition("One line only"))
        assertEquals("   ", HallucinationGuard.collapseIntraRepetition("   "))
    }
}

class ChunkTimelineTest {

    private val timeline = ChunkTimeline(sampleRate = 16_000)

    private fun chunkOfMs(ms: Double, originMs: Double): InferenceChunk =
        InferenceChunk(ShortArray((ms * 16).toInt()), originMs)

    @Test
    fun `absolute mapping adds chunk origin to relative times`() {
        val chunk = chunkOfMs(4_000.0, originMs = 10_000.0)
        val out = timeline.mapAbsolute(
            chunk,
            listOf(
                ChunkTimeline.RelSegment("one", 0.0, 1_500.0),
                ChunkTimeline.RelSegment("two", 2_000.0, 3_500.0),
            ),
        )

        assertEquals(10_000.0, out[0].t0Ms, 0.001)
        assertEquals(11_500.0, out[0].t1Ms, 0.001)
        assertEquals(12_000.0, out[1].t0Ms, 0.001)
        assertEquals(13_500.0, out[1].t1Ms, 0.001)
    }

    @Test
    fun `absolute mapping clamps out-of-range relatives`() {
        val chunk = chunkOfMs(4_000.0, originMs = 0.0)
        val out = timeline.mapAbsolute(
            chunk,
            listOf(ChunkTimeline.RelSegment("x", -50.0, 99_999.0)),
        )
        assertEquals(0.0, out[0].t0Ms, 0.001)
        assertEquals(4_000.0, out[0].t1Ms, 0.001)
    }

    @Test
    fun `interpolation fallback covers whole chunk proportionally to length`() {
        val chunk = chunkOfMs(4_000.0, originMs = 7_000.0)
        val out = timeline.assignTimes(chunk, listOf("short", "a much longer line here"))

        assertEquals(2, out.size)
        // Coverage: first starts at origin, second ends at chunk end.
        assertEquals(7_000.0, out[0].t0Ms, 0.001)
        assertEquals(11_000.0, out[1].t1Ms, 0.001)
        // Contiguity.
        assertEquals(out[0].t1Ms, out[1].t0Ms, 0.001)
        // Proportionality: longer text gets a longer span.
        assertTrue(out[1].t1Ms - out[1].t0Ms > out[0].t1Ms - out[0].t0Ms)
    }

    @Test
    fun `interpolation with empty list yields empty output`() {
        assertTrue(timeline.assignTimes(chunkOfMs(1_000.0, 0.0), emptyList()).isEmpty())
    }
}