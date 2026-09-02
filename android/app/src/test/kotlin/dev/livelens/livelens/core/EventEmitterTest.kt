package dev.livelens.livelens.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Contract §3 envelope tests: every emitted event is a map stamped with
 * the wire `type` and `"v": 1`, with body fields merged verbatim.
 */
class EventEmitterTest {

    private class RecordingSink : EventEmitter.Sink {
        val received = mutableListOf<Map<String, Any?>>()
        var detached = false
        override fun success(event: Any?) {
            @Suppress("UNCHECKED_CAST")
            (event as? Map<String, Any?>)?.let { received.add(it) }
        }
    }

    @Test
    fun `final event carries full contract shape`() {
        val sink = RecordingSink()
        val em = EventEmitter().also { it.attach(sink) }
        em.final(
            sessionId = "s1", segId = "s1-0", t0 = 100.0, t1 = 4200.0,
            srcLang = "en", src = "hello", en = "hello", conf = 0.9,
        )
        val ev = sink.received.single()
        assertEquals("final", ev["type"])
        assertEquals(1, ev["v"])
        assertEquals("s1", ev["sessionId"])
        assertEquals("s1-0", ev["segId"])
        assertEquals(100.0, ev["t0"])
        assertEquals(4200.0, ev["t1"])
        assertEquals("hello", ev["src"])
    }

    @Test
    fun `state event carries value and detail`() {
        val sink = RecordingSink()
        val em = EventEmitter().also { it.attach(sink) }
        em.state("paused", "user")
        val ev = sink.received.single()
        assertEquals("state", ev["type"])
        assertEquals(1, ev["v"])
        assertEquals("paused", ev["value"])
        assertEquals("user", ev["detail"])
    }

    @Test
    fun `perf event integers stay integers`() {
        val sink = RecordingSink()
        val em = EventEmitter().also { it.attach(sink) }
        em.perf(rtfMsPerSec = 120, queueDepth = 0, rssMb = 220.5, batteryDrop = 1.0)
        val ev = sink.received.single()
        assertTrue(ev["rtfMsPerSec"] is Int)
        assertTrue(ev["queueDepth"] is Int)
    }

    @Test
    fun `no listener drops events silently`() {
        val em = EventEmitter()
        em.state("capturing") // must not throw
    }

    @Test
    fun `detach stops delivery`() {
        val sink = RecordingSink()
        val em = EventEmitter().also { it.attach(sink) }
        em.detach()
        em.state("capturing")
        assertNull(sink.received.firstOrNull())
    }

    @Test
    fun `spoolPending carries count`() {
        val sink = RecordingSink()
        val em = EventEmitter().also { it.attach(sink) }
        em.spoolPending(3)
        val ev = sink.received.single()
        assertEquals("spoolPending", ev["type"])
        assertEquals(3, ev["count"])
    }
}
