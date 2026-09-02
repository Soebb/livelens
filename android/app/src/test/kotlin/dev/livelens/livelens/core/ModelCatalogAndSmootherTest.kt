package dev.livelens.livelens.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Epic 6/7 pure-logic tests: the curated registry invariants (E-01) and the
 * auto-detect smoothing policy (F-03). No Android framework involved.
 */
class ModelCatalogAndSmootherTest {

    // -- E-01 registry invariants --------------------------------------------

    @Test
    fun `catalog ships the three curated tiers`() {
        val tiers = ModelCatalog.all.map { it.tier }.sorted()
        assertEquals(listOf("balanced", "fast", "quality"), tiers)
    }

    @Test
    fun `catalog ids are unique and non-empty`() {
        val ids = ModelCatalog.all.map { it.id }
        assertEquals(ids.size, ids.toSet().size)
        assertTrue(ids.all { it.isNotBlank() })
    }

    @Test
    fun `byId resolves every catalog entry and rejects unknown`() {
        for (spec in ModelCatalog.all) {
            assertEquals(spec, ModelCatalog.byId(spec.id))
        }
        assertEquals(null, ModelCatalog.byId("no-such-model"))
    }

    @Test
    fun `downloadable entries carry sha256 for integrity verification`() {
        for (spec in ModelCatalog.all.filter { !it.bundled }) {
            assertTrue(spec.files.isNotEmpty())
            // Every downloadable file must have a real digest (E-02 verify step).
            for (f in spec.files) {
                assertTrue("${spec.id}:${f.name} missing sha256", f.sha256.length == 64)
            }
        }
    }

    @Test
    fun `bundled entries declare an asset source directory`() {
        for (spec in ModelCatalog.all.filter { it.bundled }) {
            assertNotNull("${spec.id} bundled without assetDir", spec.assetDir)
        }
        for (spec in ModelCatalog.all.filter { !it.bundled }) {
            assertEquals("${spec.id} must not bundle assets", null, spec.assetDir)
        }
    }

    @Test
    fun `tasks are a subset of the whisper task vocabulary`() {
        for (spec in ModelCatalog.all) {
            assertTrue(spec.tasks.all { it == "transcribe" || it == "translate" })
            assertTrue("${spec.id} has no tasks", spec.tasks.isNotEmpty())
        }
    }

    @Test
    fun `languages are iso-639-1 short codes and include english`() {
        for (spec in ModelCatalog.all) {
            assertTrue(spec.languages.all { it.length == 2 })
            assertTrue("${spec.id} must transcribe en (HT-3 target)", "en" in spec.languages)
        }
    }

    @Test
    fun `quality tier is RAM-gated above the others`() {
        val byTier = ModelCatalog.all.associateBy { it.tier }
        assertTrue(byTier.getValue("quality").minTotalRamMb > byTier.getValue("balanced").minTotalRamMb)
        assertTrue(byTier.getValue("balanced").minTotalRamMb >= byTier.getValue("fast").minTotalRamMb)
    }

    // -- F-03 smoothing policy -----------------------------------------------

    @Test
    fun `forced language always wins`() {
        val s = LangSmoother()
        s.resolve(5_000, "ja", null)
        assertEquals("ko", s.resolve(1_000, "ja", "ko"))
        assertEquals("ko", s.resolve(10_000, "ja", "ko"))
    }

    @Test
    fun `short utterances reuse the prior vote without joining the window`() {
        val s = LangSmoother()
        assertEquals("auto", s.resolve(1_000, "ja", null)) // empty history
        s.resolve(3_000, "ja", null) // seed the window
        assertEquals("ja", s.resolve(800, "ko", null)) // short: prior wins
        // The short detection never joined; a confident ko only ties 1:1 and
        // the older language wins ties -> still ja.
        assertEquals("ja", s.resolve(3_000, "ko", null))
        // A second ko breaks the tie.
        assertEquals("ko", s.resolve(3_000, "ko", null))
    }

    @Test
    fun `confident majority flips after enough evidence`() {
        val s = LangSmoother()
        s.resolve(3_000, "ja", null)
        s.resolve(3_000, "ko", null)
        s.resolve(3_000, "ko", null)
        assertEquals("ko", s.resolve(3_000, "ko", null))
    }

    @Test
    fun `window is bounded and older language wins ties`() {
        val s = LangSmoother(windowSize = 2)
        s.resolve(3_000, "ja", null)
        s.resolve(3_000, "ko", null)
        s.resolve(3_000, "ja", null) // window now ja,ko -> older ja wins tie
        assertEquals("ja", s.resolve(3_000, "ko", null))
    }

    @Test
    fun `unconfident or unknown detections are ignored`() {
        val s = LangSmoother()
        s.resolve(3_000, "ja", null)
        assertEquals("ja", s.resolve(3_000, "auto", null))
        assertEquals("ja", s.resolve(3_000, "  ", null))
        assertEquals("ja", s.resolve(3_000, "JA", null)) // normalized lowercase
    }

    @Test
    fun `reset clears state`() {
        val s = LangSmoother()
        s.resolve(3_000, "ja", null)
        s.reset()
        // History gone: a short utterance falls back to "auto", not the prior.
        assertEquals("auto", s.resolve(1_000, "ko", null))
    }
}
