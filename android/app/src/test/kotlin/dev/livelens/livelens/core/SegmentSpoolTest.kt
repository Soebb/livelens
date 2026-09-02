package dev.livelens.livelens.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class SegmentSpoolTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private fun spool(): SegmentSpool =
        SegmentSpool(File(tmp.root, "spool.jsonl"))

    private fun sample(
        segId: String = "seg-1",
        src: String = "そろそろ出発したほうがいいと思います。",
        en: String = "I think we should leave soon.",
    ) = SegmentSpool.SpooledSegment(
        sessionId = "sess-1",
        segId = segId,
        t0Ms = 1234.5,
        t1Ms = 5678.0,
        srcLang = "ja",
        src = src,
        en = en,
        conf = 0.87,
    )

    @Test
    fun `append then readPending round-trips exactly`() {
        val s = spool()
        assertTrue(s.append(sample()))
        val pending = s.readPending()

        assertEquals(1, pending.size)
        val got = pending[0]
        assertEquals("sess-1", got.sessionId)
        assertEquals("seg-1", got.segId)
        assertEquals(1234.5, got.t0Ms, 0.001)
        assertEquals(5678.0, got.t1Ms, 0.001)
        assertEquals("ja", got.srcLang)
        assertEquals("そろそろ出発したほうがいいと思います。", got.src)
        assertEquals("I think we should leave soon.", got.en)
        assertEquals(0.87, got.conf, 0.001)
    }

    @Test
    fun `multiple appends preserve order`() {
        val s = spool()
        s.append(sample(segId = "a"))
        s.append(sample(segId = "b"))
        s.append(sample(segId = "c"))

        val pending = s.readPending()
        assertEquals(listOf("a", "b", "c"), pending.map { it.segId })
    }

    @Test
    fun `special characters survive escaping round-trip`() {
        val s = spool()
        val tricky = sample(
            src = "He said \"quoted\" and \\ backslash\nnewline\ttab",
            en = "line1\nline2",
        )
        s.append(tricky)

        val got = s.readPending().single()
        assertEquals("He said \"quoted\" and \\ backslash\nnewline\ttab", got.src)
        assertEquals("line1\nline2", got.en)
    }

    @Test
    fun `torn final line is dropped not fatal`() {
        val s = spool()
        s.append(sample(segId = "good"))
        // Simulate a crash mid-write: append a partial line without newline.
        File(tmp.root, "spool.jsonl").appendText("{\"type\":\"final\",\"v\":1,\"sessionId\":\"sess-1\",\"segId\":\"torn\"")

        val pending = s.readPending()
        assertEquals(1, pending.size)
        assertEquals("good", pending[0].segId)
    }

    @Test
    fun `markImported clears the spool`() {
        val s = spool()
        s.append(sample())
        assertEquals(1, s.pendingCount())

        assertTrue(s.markImported())
        assertEquals(0, s.pendingCount())
        assertFalse(File(tmp.root, "spool.jsonl").exists())
    }

    @Test
    fun `readPending on missing file returns empty`() {
        val s = spool()
        assertTrue(s.readPending().isEmpty())
        assertEquals(0, s.pendingCount())
    }

    @Test
    fun `blank lines are ignored`() {
        val s = spool()
        s.append(sample(segId = "a"))
        File(tmp.root, "spool.jsonl").appendText("\n\n")
        s.append(sample(segId = "b"))

        val pending = s.readPending()
        assertEquals(listOf("a", "b"), pending.map { it.segId })
    }

    @Test
    fun `garbage line is skipped`() {
        val s = spool()
        s.append(sample(segId = "a"))
        File(tmp.root, "spool.jsonl").appendText("not json at all\n")
        s.append(sample(segId = "b"))

        val pending = s.readPending()
        assertEquals(listOf("a", "b"), pending.map { it.segId })
    }
}