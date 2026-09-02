package dev.livelens.livelens

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import dev.livelens.livelens.core.SubtitleLineBuilder
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Floating live-caption overlay (Epic 4, C-02/C-03/C-04/C-06, visual.md §4.6).
 *
 * Hosted by [CaptureService] so it lives exactly as long as a session
 * (the FGS keeps the process foregrounded — required for overlay windows
 * to survive the app going to the background).
 *
 * View tree: root touch surface → glass card (chips row, source line,
 * main line). Fed finalized segments from [CaptureEngine] via
 * [updateLine]; line assembly/merging uses [SubtitleLineBuilder] (C-01).
 *
 * Gestures (C-02): drag moves the window (clamped to display, position
 * persisted throttled ≤ 1 write / 500 ms), tap toggles minimal⇄expanded,
 * long-press copies the current line to the clipboard (C-06 v1 — no
 * focusable dialog needed, the overlay window stays NOT_FOCUSABLE).
 */
class OverlayController(private val context: Context) {

    private val main = Handler(Looper.getMainLooper())
    private val lines = SubtitleLineBuilder()

    private var windowManager: WindowManager? = null
    private var root: FrameLayout? = null
    private var card: LinearLayout? = null
    private var chipRow: LinearLayout? = null
    private var controlRow: LinearLayout? = null
    private var pauseButton: TextView? = null
    private var sourceView: TextView? = null
    private var mainView: TextView? = null
    private var params: WindowManager.LayoutParams? = null

    private var expanded = true
    private var style = OverlayStyle()

    // gesture bookkeeping
    private var downRawX = 0f
    private var downRawY = 0f
    private var startWindowX = 0
    private var startWindowY = 0
    private var dragging = false
    private var longPressFired = false
    private var lastPosSaveMs = 0L

    private val idleRunnable = Runnable { collapse() }
    private val longPressRunnable = Runnable {
        longPressFired = true
        copyCurrentLine()
    }

    val isAttached: Boolean get() = root != null

    // ------------------------------------------------------------------ //
    // Lifecycle

    /** Adds the overlay window; no-op when `SYSTEM_ALERT_WINDOW` is missing. */
    fun attach() {
        if (root != null) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            !Settings.canDrawOverlays(context)
        ) {
            return // graceful: session continues, overlay just doesn't show
        }
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val cardView = buildViewTree()
        val lp = WindowManager.LayoutParams(
            cardWidthPx(wm),
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
        }
        restorePosition(lp, wm)
        applyStyleTo(cardView, style, lp, wm)

        try {
            wm.addView(cardView, lp)
        } catch (_: Throwable) {
            // Rare OEM/BadToken failure: degrade exactly like the missing-
            // permission branch — the session continues without an overlay.
            return
        }
        windowManager = wm
        root = cardView
        card = cardView.findViewById(R.id.overlay_card)
        chipRow = cardView.findViewById(R.id.overlay_chips)
        sourceView = cardView.findViewById(R.id.overlay_source)
        mainView = cardView.findViewById(R.id.overlay_main)
        params = lp
        lines.clear()
        applyExpandedState()
    }

    fun detach() {
        main.removeCallbacks(idleRunnable)
        main.removeCallbacks(longPressRunnable)
        val v = root ?: return
        try {
            windowManager?.removeView(v)
        } catch (_: Throwable) {}
        root = null
        card = null
        chipRow = null
        controlRow = null
        pauseButton = null
        sourceView = null
        mainView = null
        params = null
        windowManager = null
    }

    // ------------------------------------------------------------------ //
    // Content feed

    /** One finalized engine segment (src = model text, en = translation). */
    fun updateLine(src: String, en: String) {
        main.post {
            val view = mainView ?: return@post
            val line = lines.onFinal(segId = "", text = en, t0Ms = 0.0, t1Ms = 0.0)
            view.text = line.text
            if (style.showBilingual) sourceView?.text = src
            expand()
            restartIdleTimer()
        }
    }

    /** Clears on-screen text (pause/stop/session start). */
    fun clearLines() {
        main.post {
            lines.clear()
            mainView?.text = ""
            sourceView?.text = ""
        }
    }

    /** Status chip: "paused" | "thermal" | "battery", or null to clear. */
    fun showChip(kind: String?) {
        main.post {
            val row = chipRow ?: return@post
            row.removeAllViews()
            val label = when (kind) {
                "paused" -> "⏸ Paused"
                "thermal" -> "🌡 Cooling down"
                "battery" -> "🔋 Low battery mode"
                else -> null
            }
            if (label != null) {
                row.addView(chipView(label))
                row.visibility = View.VISIBLE
            } else {
                row.visibility = View.GONE
            }
            // Keep the overlay's pause button in sync with engine reality
            // (governor pauses, auto-resumes, manual resumes from elsewhere).
            setPauseLabel(if (kind == "paused") RESUME_LABEL else PAUSE_LABEL)
            applyExpandedState()
        }
    }

    // ------------------------------------------------------------------ //
    // Style

    /** Applies a §2.4 style push live (safe before attach — just caches). */
    fun applyStyle(next: OverlayStyle) {
        style = next
        val v = root ?: return
        val lp = params ?: return
        val wm = windowManager ?: return
        main.post {
            // Re-check: detach() may have run while this post was pending
            // (session stopped / projection revoked) — mutating a window
            // that is no longer attached crashes with
            // IllegalArgumentException, so bail out instead.
            if (root !== v) return@post
            applyStyleTo(v, next, lp, wm)
            if (!next.showBilingual) sourceView?.text = ""
            restartIdleTimer()
        }
    }

    private fun applyStyleTo(
        v: View,
        s: OverlayStyle,
        lp: WindowManager.LayoutParams,
        wm: WindowManager,
    ) {
        val c = v.findViewById<LinearLayout>(R.id.overlay_card)
        val src = v.findViewById<TextView>(R.id.overlay_source)
        val mainTx = v.findViewById<TextView>(R.id.overlay_main)

        val bgAlpha = (s.backgroundOpacity * 255).roundToInt().coerceIn(0, 255)
        val baseColor =
            if (s.theme == "solid") Color.parseColor("#0B0C10") else Color.parseColor("#16181F")
        val strokeColor = if (s.theme == "solid") 0x40FFFFFF else 0x1AFFFFFF
        c.background = GradientDrawable().apply {
            setColor((bgAlpha shl 24) or (baseColor and 0x00FFFFFF))
            cornerRadius = s.cornerRadiusPx.toFloat()
            setStroke(dp(1), strokeColor)
        }

        mainTx.textSize = s.fontSizeSp.toFloat()
        mainTx.maxLines = s.maxLines
        mainTx.gravity = gravityOf(s.textAlign)
        if (s.textShadowArgb != 0) {
            mainTx.setShadowLayer(2f, 0f, 1f, s.textShadowArgb)
        } else {
            mainTx.setShadowLayer(0f, 0f, 0f, 0)
        }
        src.visibility = if (s.showBilingual) View.VISIBLE else View.GONE

        // Window width = maxWidthFraction of the display (wireframe: 78%).
        lp.width = cardWidthPx(wm, s.maxWidthFraction)
        try {
            windowManager?.updateViewLayout(v, lp)
        } catch (_: IllegalArgumentException) {
            // Window removed concurrently (detach race) — nothing to style.
        }
    }

    private fun gravityOf(align: String) = when (align) {
        "left" -> Gravity.START
        "right" -> Gravity.END
        else -> Gravity.CENTER_HORIZONTAL
    }

    // ------------------------------------------------------------------ //
    // Minimal / expanded states (C-03)

    private fun expand() {
        if (!expanded) {
            expanded = true
            applyExpandedState()
        }
    }

    private fun collapse() {
        if (!expanded) return
        expanded = false
        applyExpandedState()
    }

    /** 300 ms fade + scale .98 (visual.md §4.4 motion spec). */
    private fun applyExpandedState() {
        val c = card ?: return
        chipRow?.visibility =
            if (expanded && (chipRow?.childCount ?: 0) > 0) View.VISIBLE else View.GONE
        controlRow?.visibility = if (expanded) View.VISIBLE else View.GONE
        sourceView?.visibility =
            if (expanded && style.showBilingual) View.VISIBLE else View.GONE
        c.animate()
            .scaleX(if (expanded) 1f else 0.98f)
            .scaleY(if (expanded) 1f else 0.98f)
            .alpha(if (expanded) 1f else 0.88f)
            .setDuration(300)
            .start()
    }

    private fun restartIdleTimer() {
        main.removeCallbacks(idleRunnable)
        if (style.idleCollapseSeconds > 0 && isAttached) {
            main.postDelayed(idleRunnable, style.idleCollapseSeconds * 1000L)
        }
    }

    // ------------------------------------------------------------------ //
    // Gestures (C-02 / C-06)

    private fun buildViewTree(): FrameLayout {
        val rootLayout = FrameLayout(context)

        val cardView = LinearLayout(context).apply {
            id = R.id.overlay_card
            orientation = LinearLayout.VERTICAL
            setPadding(dp(14), dp(10), dp(14), dp(12))
        }

        val chips = LinearLayout(context).apply {
            id = R.id.overlay_chips
            orientation = LinearLayout.HORIZONTAL
            visibility = View.GONE
        }

        val source = TextView(context).apply {
            id = R.id.overlay_source
            setTextColor(0xFFA6ADBB.toInt())
            textSize = 12f
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            visibility = View.GONE
            setPadding(0, dp(4), 0, 0)
        }

        val mainText = TextView(context).apply {
            id = R.id.overlay_main
            setTextColor(0xFFF2F4F8.toInt())
            textSize = style.fontSizeSp.toFloat()
            typeface = Typeface.SANS_SERIF
            ellipsize = android.text.TextUtils.TruncateAt.END
        }

        val controls = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END
            visibility = View.GONE
        }
        val pause = controlButton(PAUSE_LABEL).apply {
            setOnClickListener {
                // Optimistic flip; showChip()/the service reconcile reality.
                val engine = EventsBus.engine
                val nowPaused = engine?.isPaused ?: false
                setPauseLabel(if (nowPaused) PAUSE_LABEL else RESUME_LABEL)
                sendServiceAction(
                    if (nowPaused) CaptureService.ACTION_RESUME else CaptureService.ACTION_PAUSE,
                )
            }
        }
        pauseButton = pause
        val stop = controlButton("✕").apply {
            setOnClickListener { sendServiceAction(CaptureService.ACTION_STOP) }
        }
        controls.addView(pause)
        controls.addView(stop)
        controlRow = controls

        cardView.addView(chips)
        cardView.addView(mainText)
        cardView.addView(source)
        cardView.addView(controls)
        rootLayout.addView(
            cardView,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )

        @SuppressLint("ClickableViewAccessibility")
        fun wireTouch() {
            cardView.setOnTouchListener { _, ev ->
                handleTouch(ev)
                true
            }
        }
        wireTouch()
        return rootLayout
    }

    private fun handleTouch(ev: MotionEvent) {
        val lp = params ?: return
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downRawX = ev.rawX
                downRawY = ev.rawY
                startWindowX = lp.x
                startWindowY = lp.y
                dragging = false
                longPressFired = false
                main.postDelayed(longPressRunnable, 600L)
            }
            MotionEvent.ACTION_MOVE -> {
                if (!dragging &&
                    (abs(ev.rawX - downRawX) > touchSlop() || abs(ev.rawY - downRawY) > touchSlop())
                ) {
                    dragging = true
                    main.removeCallbacks(longPressRunnable)
                }
                if (dragging) {
                    val wm = windowManager ?: return
                    lp.x = clampX(startWindowX + (ev.rawX - downRawX).roundToInt(), lp, wm)
                    lp.y = clampY(startWindowY + (ev.rawY - downRawY).roundToInt(), lp, wm)
                    try {
                        windowManager?.updateViewLayout(root, lp)
                    } catch (_: IllegalArgumentException) {
                        // Window torn down mid-gesture (session stop racing
                        // the touch stream) — drop this frame; later events
                        // re-check `params` and bail out on their own.
                    }
                    // throttle position persistence ≤ 1 write / 500 ms (§2.4)
                    val now = System.currentTimeMillis()
                    if (now - lastPosSaveMs >= 500) {
                        lastPosSaveMs = now
                        persistPosition(lp)
                    }
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                main.removeCallbacks(longPressRunnable)
                if (!dragging && !longPressFired && ev.actionMasked == MotionEvent.ACTION_UP) {
                    // tap → toggle minimal/expanded (C-03)
                    expanded = !expanded
                    applyExpandedState()
                    restartIdleTimer()
                }
                if (dragging) persistPosition(lp)
                dragging = false
            }
        }
    }

    private fun touchSlop(): Int =
        android.view.ViewConfiguration.get(context).scaledTouchSlop

    private fun copyCurrentLine() {
        val text = lines.onScreen?.text?.takeIf { it.isNotBlank() } ?: return
        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cm.setPrimaryClip(ClipData.newPlainText("LiveLens line", text))
        Toast.makeText(context, "Line copied", Toast.LENGTH_SHORT).show()
    }

    // ------------------------------------------------------------------ //
    // Position (C-02 persistence)

    private fun restorePosition(lp: WindowManager.LayoutParams, wm: WindowManager) {
        val saved = OverlayStore.loadPosition(context)
        if (saved != null) {
            lp.x = clampX(saved.x, lp, wm)
            lp.y = clampY(saved.y, lp, wm)
        } else {
            // default: upper area, horizontally centered
            lp.x = (displayWidth(wm) - cardWidthPx(wm)) / 2
            lp.y = dp(96)
        }
    }

    private fun persistPosition(lp: WindowManager.LayoutParams) {
        OverlayStore.savePosition(
            context,
            OverlayPosition(lp.x, lp.y, lp.width, root?.height ?: 0),
        )
    }

    private fun displayWidth(wm: WindowManager): Int =
        wm.metrics().first

    private fun displayHeight(wm: WindowManager): Int =
        wm.metrics().second

    private fun cardWidthPx(wm: WindowManager, fraction: Double = style.maxWidthFraction): Int =
        (displayWidth(wm) * fraction).roundToInt()

    private fun clampX(x: Int, lp: WindowManager.LayoutParams, wm: WindowManager): Int =
        x.coerceIn(0, (displayWidth(wm) - lp.width).coerceAtLeast(0))

    private fun clampY(y: Int, lp: WindowManager.LayoutParams, wm: WindowManager): Int {
        val h = root?.height ?: 0
        return y.coerceIn(0, (displayHeight(wm) - h).coerceAtLeast(0))
    }

    private fun WindowManager.metrics(): Pair<Int, Int> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val b = maximumWindowMetrics.bounds
            b.width() to b.height()
        } else {
            @Suppress("DEPRECATION")
            defaultDisplay.width to defaultDisplay.height
        }

    private fun dp(v: Int): Int = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP,
        v.toFloat(),
        context.resources.displayMetrics,
    ).roundToInt()

    private fun chipView(label: String): TextView = TextView(context).apply {
        text = label
        textSize = 11f
        setTextColor(0xFFFFB65C.toInt())
        setPadding(dp(8), dp(2), dp(8), dp(2))
        background = GradientDrawable().apply {
            cornerRadius = dp(999).toFloat()
            setColor(0x33FFB65C)
        }
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { bottomMargin = dp(6) }
    }

    // ------------------------------------------------------------------ //
    // Overlay controls (pause/resume + stop)

    private companion object {
        const val PAUSE_LABEL = "⏸ Pause"
        const val RESUME_LABEL = "▶ Resume"
    }

    private fun setPauseLabel(label: String) {
        pauseButton?.text = label
    }

    /** Overlay buttons ride the running FGS — service intents are allowed. */
    private fun sendServiceAction(action: String) {
        runCatching {
            context.startService(
                Intent(context, CaptureService::class.java).setAction(action),
            )
        }
    }

    /** Compact pill button matching the chip styling, but clickable. */
    private fun controlButton(label: String): TextView = TextView(context).apply {
        text = label
        textSize = 11f
        setTextColor(0xFFA6ADBB.toInt())
        setPadding(dp(10), dp(4), dp(10), dp(4))
        isClickable = true
        isFocusable = false // window stays NOT_FOCUSABLE
        background = GradientDrawable().apply {
            cornerRadius = dp(999).toFloat()
            setColor(0x22FFFFFF)
        }
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { marginStart = dp(6) }
    }
}
