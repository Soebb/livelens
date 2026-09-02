package dev.livelens.livelens

import android.content.Context
import android.content.SharedPreferences

/**
 * Overlay configuration (contract §2.4) — native mirror of the Dart
 * `OverlayStyle` DTO. Every field carries the contract default so a
 * partial wire map is always safe to parse.
 */
data class OverlayStyle(
    val fontSizeSp: Double = 18.0,
    val backgroundOpacity: Double = 0.82,
    val maxLines: Int = 2,
    val textAlign: String = "center",
    val cornerRadiusPx: Double = 20.0,
    val textShadowArgb: Int = 0xFF000000.toInt(),
    val theme: String = "glass",
    val showBilingual: Boolean = false,
    val idleCollapseSeconds: Int = 3,
    val maxWidthFraction: Double = 0.78,
) {
    companion object {
        /** Parses a §2.4 wire map; unknown/absent keys keep defaults. */
        fun fromWire(args: Any?): OverlayStyle {
            val m = args as? Map<*, *> ?: return OverlayStyle()
            fun num(key: String): Double? = when (val v = m[key]) {
                is Double -> v
                is Int -> v.toDouble()
                is Long -> v.toDouble()
                else -> null
            }
            fun str(key: String): String? = m[key] as? String
            return OverlayStyle(
                fontSizeSp = num("fontSizeSp") ?: 18.0,
                backgroundOpacity = (num("backgroundOpacity") ?: 0.82).coerceIn(0.0, 1.0),
                maxLines = (num("maxLines") ?: 2.0).toInt().coerceIn(1, 5),
                textAlign = when (str("textAlign")) {
                    "left", "right" -> str("textAlign")!!
                    else -> "center"
                },
                cornerRadiusPx = num("cornerRadiusPx") ?: 20.0,
                textShadowArgb = (num("textShadowArgb") ?: 0xFF000000.toDouble()).toInt(),
                theme = if (str("theme") == "solid") "solid" else "glass",
                showBilingual = m["showBilingual"] as? Boolean ?: false,
                idleCollapseSeconds = (num("idleCollapseSeconds") ?: 3.0).toInt().coerceIn(0, 10),
                maxWidthFraction = (num("maxWidthFraction") ?: 0.78).coerceIn(0.1, 1.0),
            )
        }
    }
}

/** A saved overlay window position in px (contract §2.4 saveOverlayPosition). */
data class OverlayPosition(val x: Int, val y: Int, val w: Int, val h: Int)

/**
 * Process-wide overlay configuration store (MainActivity ↔ CaptureService).
 * Style and last position survive process death via SharedPreferences so a
 * re-attached overlay comes back where the user left it (C-02 persistence).
 */
object OverlayStore {
    private const val PREFS = "livelens_overlay"
    private const val KEY_STYLE = "styleJson"

    @Volatile var style: OverlayStyle = OverlayStyle()
        private set

    fun load(context: Context) {
        val prefs = prefs(context)
        style = OverlayStyle.fromWire(jsonToMap(prefs.getString(KEY_STYLE, null)))
    }

    /** Live style push (contract §2.4 setOverlayStyle) — applied immediately. */
    fun apply(context: Context, next: OverlayStyle) {
        style = next
        prefs(context).edit()
            .putString(KEY_STYLE, mapToJson(wireOf(next)))
            .apply()
        OverlayBus.controller?.applyStyle(next)
    }

    fun savePosition(context: Context, p: OverlayPosition) {
        prefs(context).edit()
            .putInt("x", p.x).putInt("y", p.y)
            .putInt("w", p.w).putInt("h", p.h)
            .apply()
    }

    fun loadPosition(context: Context): OverlayPosition? {
        val p = prefs(context)
        if (!p.contains("x")) return null
        return OverlayPosition(p.getInt("x", 0), p.getInt("y", 0), p.getInt("w", 0), p.getInt("h", 0))
    }

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun wireOf(s: OverlayStyle) = mapOf(
        "fontSizeSp" to s.fontSizeSp,
        "backgroundOpacity" to s.backgroundOpacity,
        "maxLines" to s.maxLines,
        "textAlign" to s.textAlign,
        "cornerRadiusPx" to s.cornerRadiusPx,
        "textShadowArgb" to s.textShadowArgb,
        "theme" to s.theme,
        "showBilingual" to s.showBilingual,
        "idleCollapseSeconds" to s.idleCollapseSeconds,
        "maxWidthFraction" to s.maxWidthFraction,
    )

    // Tiny flat-string-map JSON encoder/decoder — enough for the §2.4
    // shape without pulling in org.json (which is fine on Android, but
    // keeping it dependency-free keeps this unit-testable on the JVM).
    private fun mapToJson(m: Map<*, *>): String {
        val sb = StringBuilder("{")
        var first = true
        for (e in m.entries) {
            if (!first) sb.append(',')
            first = false
            sb.append('"').append(e.key).append("\":")
            val v = e.value
            if (v is String) sb.append('"').append(v).append('"') else sb.append(v)
        }
        return sb.append('}').toString()
    }

    private fun jsonToMap(raw: String?): Map<*, *> {
        if (raw.isNullOrBlank()) return emptyMap<Any?, Any>()
        val out = HashMap<String, Any>()
        val body = raw.trim().removePrefix("{").removeSuffix("}")
        if (body.isBlank()) return out
        for (pair in body.split(",")) {
            val kv = pair.split(":", limit = 2)
            if (kv.size != 2) continue
            val key = kv[0].trim().removeSurrounding("\"")
            val v = kv[1].trim()
            out[key] = when {
                v.startsWith("\"") -> v.removeSurrounding("\"")
                v == "true" -> true
                v == "false" -> false
                v.contains('.') -> v.toDoubleOrNull() ?: v
                else -> v.toIntOrNull() ?: v
            }
        }
        return out
    }
}

/** Shared handle so MainActivity can reach the live overlay (if attached). */
object OverlayBus {
    @Volatile var controller: OverlayController? = null
}
