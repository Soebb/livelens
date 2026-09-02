package dev.livelens.livelens.core

import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Breadcrumb journal (field diagnostics): timestamped progress markers
 * appended to `filesDir/diagnostics-log.txt` across the exact window where
 * the process has been observed to die without an uncaught Java exception
 * (native JNI/ONNX abort or LMK kill — neither reaches the Java crash
 * handler, so `crash-log.txt` stays empty).
 *
 * The last breadcrumb before a silent death localizes the native call that
 * killed the process; the journal is surfaced through `getCrashLog`
 * (Settings → Diagnostics) together with the crash log itself.
 *
 * Blocking IO on a bounded file — call volume is tiny (a handful of marks
 * per session), so this is safe from any thread including pipeline ones.
 */
object Breadcrumbs {

    private const val FILE = "diagnostics-log.txt"
    private const val MAX_BYTES = 160_000
    private val lock = Any()

    /** Installed once from [dev.livelens.livelens.LivelensApplication]. */
    @Volatile
    private var logFile: File? = null

    fun init(context: android.content.Context) {
        logFile = File(context.applicationInfo.dataDir, FILE)
        mark("journal.init")
    }

    fun mark(event: String, detail: String = "") {
        val f = logFile ?: return
        try {
            synchronized(lock) {
                if (f.length() > MAX_BYTES) {
                    val text = f.readText()
                    f.writeText(text.substring(text.length / 2))
                }
                val stamp = SimpleDateFormat("HH:mm:ss.SSS", Locale.US).format(Date())
                f.appendText(
                    buildString {
                        append(stamp).append(" [").append(Thread.currentThread().name).append("] ")
                        append(event)
                        if (detail.isNotEmpty()) append(" | ").append(detail)
                        append('\n')
                    },
                )
            }
        } catch (_: Throwable) {
            // Diagnostics must never be the crash.
        }
    }

    fun readAll(context: android.content.Context): String = try {
        File(context.applicationInfo.dataDir, FILE).readText()
    } catch (_: Throwable) {
        ""
    }
}
