package dev.livelens.livelens.core

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.charset.StandardCharsets

/**
 * Crash-resilient disk spool for finalized segments (D-03, architecture §3.1).
 *
 * Kotlin owns the audio truth; Flutter owns the database. This spool is the
 * seam: segments are appended as JSONL lines the moment they're finalized,
 * so a process death never loses them. On relaunch, [readPending] returns
 * the un-imported lines for idempotent upsert by segment id (D-03).
 *
 * Design:
 * - Append-only JSONL (one segment per line) — no rewrite on the hot path.
 * - [markImported] truncates the file once Flutter confirms reconciliation,
 *   so the spool never grows unbounded.
 * - Atomic-ish: writes go to the file directly; a torn final line (crash
 *   mid-write) is detected by [readPending] and dropped, not fatal.
 *
 * Pure Kotlin + java.io; unit-testable with a temp dir.
 */
class SegmentSpool(private val file: File) {

    /** One spooled segment, mirroring the wire `final` event shape. */
    data class SpooledSegment(
        val sessionId: String,
        val segId: String,
        val t0Ms: Double,
        val t1Ms: Double,
        val srcLang: String,
        val src: String,
        val en: String,
        val conf: Double,
    ) {
        /** JSONL line — keys match the contract §3 `final` event exactly. */
        fun toJsonLine(): String {
            val sb = StringBuilder(128)
            sb.append("{\"type\":\"final\",\"v\":1")
            sb.append(",\"sessionId\":\"").append(escape(sessionId)).append('"')
            sb.append(",\"segId\":\"").append(escape(segId)).append('"')
            sb.append(",\"t0\":").append(t0Ms)
            sb.append(",\"t1\":").append(t1Ms)
            sb.append(",\"srcLang\":\"").append(escape(srcLang)).append('"')
            sb.append(",\"src\":\"").append(escape(src)).append('"')
            sb.append(",\"en\":\"").append(escape(en)).append('"')
            sb.append(",\"conf\":").append(conf)
            sb.append('}')
            return sb.toString()
        }

        private fun escape(s: String): String = buildString(s.length + 8) {
            for (c in s) {
                when (c) {
                    '"' -> append("\\\"")
                    '\\' -> append("\\\\")
                    '\n' -> append("\\n")
                    '\r' -> append("\\r")
                    '\t' -> append("\\t")
                    else -> append(c)
                }
            }
        }
    }

    /**
     * Appends one segment. Returns false on I/O failure (caller may retry
     * or surface an error event); never throws.
     */
    fun append(segment: SpooledSegment): Boolean {
        return try {
            file.parentFile?.mkdirs()
            FileOutputStream(file, true).use { out ->
                out.write(segment.toJsonLine().toByteArray(StandardCharsets.UTF_8))
                out.write('\n'.code)
            }
            true
        } catch (_: IOException) {
            false
        }
    }

    /**
     * Reads all pending (un-imported) segments. A torn final line (no
     * trailing newline, e.g. crash mid-write) is dropped silently.
     * Returns empty list when the file is absent or unreadable.
     */
    fun readPending(): List<SpooledSegment> {
        if (!file.exists()) return emptyList()
        return try {
            file.readLines(StandardCharsets.UTF_8)
                .filter { it.isNotBlank() }
                .mapNotNull(::parseLine)
        } catch (_: IOException) {
            emptyList()
        }
    }

    /**
     * Clears the spool after Flutter confirms reconciliation (D-03
     * idempotent upsert). Returns false on I/O failure.
     */
    fun markImported(): Boolean = try {
        file.delete()
        true
    } catch (_: IOException) {
        false
    }

    /** Number of pending lines (for the spoolPending event count). */
    fun pendingCount(): Int = readPending().size

    private fun parseLine(line: String): SpooledSegment? {
        // Minimal JSON extraction — we control the writer, so a strict
        // hand-rolled parser is safer than pulling in a JSON lib here.
        return try {
            val m = Regex(
                """\{"type":"final","v":1,"sessionId":"(.*?)","segId":"(.*?)","t0":([0-9.]+),"t1":([0-9.]+),"srcLang":"(.*?)","src":"(.*?)","en":"(.*?)","conf":([0-9.]+)\}"""
            ).matchEntire(line) ?: return null

            SpooledSegment(
                sessionId = unescape(m.groupValues[1]),
                segId = unescape(m.groupValues[2]),
                t0Ms = m.groupValues[3].toDouble(),
                t1Ms = m.groupValues[4].toDouble(),
                srcLang = unescape(m.groupValues[5]),
                src = unescape(m.groupValues[6]),
                en = unescape(m.groupValues[7]),
                conf = m.groupValues[8].toDouble(),
            )
        } catch (_: Exception) {
            null
        }
    }

    private fun unescape(s: String): String = buildString(s.length) {
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c == '\\' && i + 1 < s.length) {
                when (s[i + 1]) {
                    '"' -> { append('"'); i += 2; continue }
                    '\\' -> { append('\\'); i += 2; continue }
                    'n' -> { append('\n'); i += 2; continue }
                    'r' -> { append('\r'); i += 2; continue }
                    't' -> { append('\t'); i += 2; continue }
                }
            }
            append(c)
            i++
        }
    }
}