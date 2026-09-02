package dev.livelens.livelens.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UtteranceAssemblerTest {

    private val ms = 1000.0 / 16_000.0

    @Test
    fun `segment pads both sides and clamps at stream start`() {
        val a = UtteranceAssembler(prePadMs = 100.0, postPadMs = 100.0)
        // feed 1 s of audio: absolute samples [0, 16000)
        a.feed(ShortArray(16_000) { it.toShort() }, originMs = 0.0)
        // speech at [1600, 4800) → pre-pad clamps at stream start:
        // padded window is [0, 6400)
        val utt = a.segment(1_600, 4_800)
        assertNotNull(utt)
        utt!!
        assertEquals(0.0, utt.audioOriginMs, 1e-6)
        assertEquals(6_400, utt.samples.size)
        assertEquals(0.toShort(), utt.samples[0])
        assertEquals(6_399.toShort(), utt.samples[utt.samples.size - 1])
    }

    @Test
    fun `post pad clamps to what has arrived`() {
        val a = UtteranceAssembler()
        a.feed(ShortArray(4_000), originMs = 0.0) // 250 ms
        // speech ends exactly at the stream head → post-pad is truncated;
        // pre-pad also clamps at 0, so the whole buffer is returned
        val utt = a.segment(1_000, 4_000)
        assertNotNull(utt)
        utt!!
        assertEquals(4_000, utt.samples.size)
    }

    @Test
    fun `buffer consumed up to segment end plus post pad`() {
        val a = UtteranceAssembler()
        a.feed(ShortArray(16_000), originMs = 0.0)
        a.segment(1_600, 4_800)!! // consumes through 6400
        assertEquals(16_000 - 6_400, a.pendingSamples)
        // next segment from same region must be trimmed away → null
        assertNull(a.segment(0, 1_000))
    }

    @Test
    fun `origins stay honest across consumed blocks`() {
        val a = UtteranceAssembler()
        a.feed(ShortArray(16_000), originMs = 1000.0) // [1000, 2000) ms
        a.feed(ShortArray(16_000), originMs = 2000.0) // [2000, 3000) ms
        // sample s maps to 1000 + s*ms ms; speech [20000, 24000) pads to
        // [18400, 25600) → origin 2150 ms, end 2600 ms
        val utt = a.segment(20_000, 24_000)!!
        assertEquals(2_150.0, utt.audioOriginMs, 1e-6)
        assertEquals(7_200, utt.samples.size)
        assertEquals(
            utt.audioOriginMs + utt.samples.size * ms,
            1000.0 + 25_600 * ms,
            1e-6,
        )
    }

    @Test
    fun `trimToPreRoll keeps only the last 100 ms during silence`() {
        val a = UtteranceAssembler()
        a.feed(ShortArray(80_000), originMs = 0.0) // 5 s of silence
        a.trimToPreRoll()
        assertEquals(1_600, a.pendingSamples)
        // later speech right at the boundary still gets its pre-roll
        a.feed(ShortArray(8_000), originMs = 5_000.0)
        val utt = a.segment(80_000, 84_000)!!
        // prepad 1600 + speech 4000 + postpad 1600
        assertEquals(7_200, utt.samples.size)
    }

    @Test
    fun `reset clears everything`() {
        val a = UtteranceAssembler()
        a.feed(ShortArray(16_000), originMs = 0.0)
        a.segment(1_600, 4_800)
        a.reset()
        assertEquals(0, a.pendingSamples)
        assertNull(a.segment(0, 1_000))
    }

    @Test
    fun `cutPartial emits all but the tail and keeps absolute positions`() {
        val a = UtteranceAssembler()
        a.feed(ShortArray(80_000), originMs = 0.0) // 5 s buffered
        val partial = a.cutPartial(keepTailMs = 320.0)!!
        assertEquals(80_000 - 320 * 16, partial.samples.size)
        assertEquals(0.0, partial.audioOriginMs, 1e-6)
        // Tail remains buffered for the continuation.
        assertEquals(320 * 16, a.pendingSamples)
        // Absolute sample space is preserved: a later VAD segment starting
        // at the tail still resolves against real session time.
        val rest = a.segment(80_000, 82_000)!!
        assertEquals(78_400.0 / 16.0, rest.audioOriginMs, 1e-6)
    }

    @Test
    fun `cutPartial returns null when only the tail is buffered`() {
        val a = UtteranceAssembler()
        a.feed(ShortArray(1_000), originMs = 0.0) // ~62 ms < keep
        assertNull(a.cutPartial(320.0))
        assertEquals(1_000, a.pendingSamples)
    }
}

class UtteranceHandOffTest {

    @Test
    fun `drainAll returns accumulated utterances exactly once`() {
        val handOff = UtteranceHandOff()
        assertTrue(handOff.isEmpty)
        assertTrue(handOff.drainAll().isEmpty())

        handOff.add(Utterance(samples = ShortArray(4), sampleRate = 16_000, audioOriginMs = 0.0))
        handOff.add(Utterance(samples = ShortArray(8), sampleRate = 16_000, audioOriginMs = 500.0))
        assertFalse(handOff.isEmpty)

        // First hop hands out everything produced during it…
        val first = handOff.drainAll()
        assertEquals(2, first.size)
        assertEquals(0.0, first[0].audioOriginMs, 1e-6)
        assertEquals(500.0, first[1].audioOriginMs, 1e-6)

        // …and the NEXT hop must NOT see them again. Returning the same
        // list on every call re-submitted every utterance ever emitted to
        // the inference queue (same two chunks decoded forever).
        assertTrue(handOff.drainAll().isEmpty())

        handOff.add(Utterance(samples = ShortArray(2), sampleRate = 16_000, audioOriginMs = 900.0))
        assertEquals(1, handOff.drainAll().size)
        assertTrue(handOff.drainAll().isEmpty())
    }
}

class InferenceExecutorTest {

    @Test
    fun `chunks decode in order on a single thread`() {
        val ex = InferenceExecutor(capacity = 8)
        val seen = ArrayList<Int>()
        var worker: Thread? = null
        ex.start(
            warmUp = { worker = Thread.currentThread() },
            decode = { c ->
                seen += c.originMs.toInt()
                Thread.sleep(1)
            },
        )
        for (i in 1..5) assertTrue(ex.submit(InferenceChunk(ShortArray(8), i.toDouble())))
        ex.shutdownDrain(2_000)
        assertEquals(listOf(1, 2, 3, 4, 5), seen)
        assertNotNull(worker)
    }

    @Test
    fun `warmUp runs before first decode`() {
        val ex = InferenceExecutor()
        val order = ArrayList<String>()
        ex.start(
            warmUp = { order += "warmup" },
            decode = { _ -> order += "decode" },
        )
        assertTrue(ex.submit(InferenceChunk(ShortArray(4), 0.0)))
        ex.shutdownDrain(2_000)
        assertEquals("warmup", order.first())
        assertTrue(order.indexOf("warmup") < order.indexOf("decode"))
    }

    @Test
    fun `full queue drops the newest chunk and counts it`() {
        val ex = InferenceExecutor(capacity = 1)
        val entered = java.util.concurrent.CountDownLatch(1)
        val gate = java.util.concurrent.CountDownLatch(1)
        val decoded = java.util.concurrent.atomic.AtomicInteger(0)
        ex.start(warmUp = {}, decode = { _ ->
            entered.countDown() // worker has taken a chunk out of the queue
            gate.await()
            decoded.incrementAndGet()
        })
        assertTrue(ex.submit(InferenceChunk(ShortArray(4), 1.0)))
        assertTrue(entered.await(2, java.util.concurrent.TimeUnit.SECONDS))
        // worker is now blocked holding chunk 1 (queue empty again)
        assertTrue(decoded.get() == 0)
        assertTrue(ex.submit(InferenceChunk(ShortArray(4), 2.0)))
        assertFalse(ex.submit(InferenceChunk(ShortArray(4), 3.0)))
        assertEquals(1, ex.depth)
        assertEquals(1L, ex.droppedChunks)
        gate.countDown()
        ex.shutdownDrain(2_000)
        // both accepted chunks decode after the gate opens; the third is
        // never decoded and stays counted as dropped
        assertTrue(decoded.get() >= 1)
        assertEquals(1L, ex.droppedChunks)
    }

    @Test
    fun `shutdown drains remaining queued work before exiting`() {
        val ex = InferenceExecutor(capacity = 8)
        val seen = ArrayList<Int>()
        ex.start(warmUp = {}, decode = { c ->
            Thread.sleep(10)
            seen += c.originMs.toInt()
        })
        for (i in 1..4) assertTrue(ex.submit(InferenceChunk(ShortArray(4), i.toDouble())))
        ex.shutdownDrain(5_000)
        assertEquals(listOf(1, 2, 3, 4), seen)
    }
}
