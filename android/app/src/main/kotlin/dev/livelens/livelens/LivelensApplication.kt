package dev.livelens.livelens

import android.app.Application
import dev.livelens.livelens.core.Breadcrumbs
import java.io.File
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Crash forensics (field diagnostics, §3.7 spirit): uncaught Java exceptions
 * are appended to `filesDir/crash-log.txt` before the default handler runs,
 * so a crash observed on a device can be read back from the app itself
 * (Settings → Diagnostics, via the `getCrashLog` control method).
 *
 * Native crashes (SIGSEGV) are NOT caught here — those need `adb logcat`.
 */
class LivelensApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        Breadcrumbs.init(this)
        Breadcrumbs.mark("app.start", "pid=${android.os.Process.myPid()}")
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            Breadcrumbs.mark(
                "app.javaCrash",
                "${throwable.javaClass.name}: ${throwable.message} on ${thread.name}",
            )
            runCatching { appendCrash(thread, throwable) }
            previous?.uncaughtException(thread, throwable)
        }
    }

    private fun appendCrash(thread: Thread, throwable: Throwable) {
        val f = File(filesDir, CRASH_FILE)
        // Bounded: drop the oldest half when the log grows past 256 KB so a
        // repeating crash cannot fill storage.
        if (f.length() > 256_000) {
            runCatching {
                val text = f.readText()
                f.writeText(text.substring(text.length / 2))
            }
        }
        val stamp = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())
        try {
            f.appendText(
                "\n==== $stamp [${thread.name}] ====\n" +
                    throwable.stackTraceToString().take(32_000),
            )
        } catch (_: IOException) {
            // storage full / IO failure — the original crash matters more
        }
    }

    companion object {
        const val CRASH_FILE = "crash-log.txt"
    }
}
