package dev.livelens.livelens

import android.content.Context

/**
 * A-03 capture-filter settings persistence. The playback-capture
 * configuration itself is filtered to `{USAGE_MEDIA, USAGE_GAME,
 * USAGE_UNKNOWN}` (A-03, see CaptureEngine.startThreads); Android's
 * AudioPlaybackCaptureConfiguration offers no per-package exclusion, so
 * the user block-list is persisted here and applied at the layers that
 * CAN honor it (segment suppression / overlay targeting, Epic 4).
 */
object CaptureFilterPrefs {
    private const val PREFS = "livelens_prefs"
    private const val KEY = "pkg_blocklist"

    fun load(context: Context): Set<String> =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getStringSet(KEY, emptySet())
            ?.toSet()
            ?: emptySet()

    fun save(context: Context, packages: Set<String>) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putStringSet(KEY, packages)
            .apply()
    }
}
