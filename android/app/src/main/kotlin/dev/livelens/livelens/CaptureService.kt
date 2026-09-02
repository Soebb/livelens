package dev.livelens.livelens

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import dev.livelens.livelens.core.Breadcrumbs
import dev.livelens.livelens.core.CaptureEngine
import dev.livelens.livelens.core.EventEmitter
import dev.livelens.livelens.core.ModelRegistry
import java.io.File

/**
 * Foreground service hosting [CaptureEngine] (A-01, architecture §3.2).
 *
 * Actions: [ACTION_START] (projection consent result attached),
 * [ACTION_PAUSE], [ACTION_RESUME], [ACTION_STOP].
 */
class CaptureService : Service() {

    private lateinit var engine: CaptureEngine

    /** Epic 4: floating caption overlay (lives exactly as long as a session). */
    private lateinit var overlay: OverlayController

    /** §3.7 silence guard nudge state (drives the notification text). */
    @Volatile private var silenceHinting = false

    override fun onCreate() {
        super.onCreate()
        Breadcrumbs.mark("service.create")
        val events = EventsBus.events
        val spool = File(getExternalFilesDir(null) ?: filesDir, "session-spool.jsonl")
        overlay = OverlayController(this).also { OverlayBus.controller = it }
        OverlayStore.load(this)
        engine = CaptureEngine(this, events, spool).apply {
            // Engine read PER DECODE via the provider so a hot-swap (E-04)
            // takes effect mid-session; NoopTranscriber fallback keeps
            // sessions honest-but-empty pre-load (§2.2).
            transcriberProvider = { ModelRegistry.transcriber }
            // §3.7 silence guard surfaces as an FGS-notification nudge
            // (G-03) — no new §3 event type (frozen set).
            onSilenceHint = { hinting ->
                silenceHinting = hinting
                updateForegroundNotification()
            }
            // Epic 4: overlay feed. The controller hops to the main thread
            // internally, so invoking from capture/inference threads is safe.
            onOverlayText = { src, en -> overlay.updateLine(src, en) }
            onOverlayChip = { kind -> overlay.showChip(kind) }
        }
        EventsBus.engine = engine
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            when (intent?.action) {
                ACTION_START -> {
                    startAsForeground()
                    engine.captureMode =
                        if (intent.getBooleanExtra(EXTRA_MIC_MODE, false)) {
                            CaptureEngine.CaptureMode.MIC
                        } else {
                            CaptureEngine.CaptureMode.PROJECTION
                        }
                    engine.start(
                        projectionResult = intent.getIntExtra(EXTRA_RESULT_CODE, 0),
                        projectionData = intent.getParcelableExtra(EXTRA_RESULT_DATA) ?: Intent(),
                        sessionId = intent.getStringExtra(EXTRA_SESSION_ID) ?: "",
                        srcLang = intent.getStringExtra(EXTRA_SRC_LANG),
                        task = intent.getStringExtra(EXTRA_TASK) ?: "translate",
                    )
                    if (engine.isRunning) {
                        // Epic 4: overlay rides the session lifecycle
                        OverlayStore.load(this)
                        overlay.clearLines()
                        overlay.attach()
                    }
                }
                ACTION_PAUSE -> {
                    engine.pause()
                    updateForegroundNotification()
                }
                ACTION_RESUME -> {
                    engine.resume()
                    updateForegroundNotification()
                }
                ACTION_CYCLE_LANG -> {
                    engine.setSourceLanguage(nextLanguage(engine.currentSrcLang))
                    updateForegroundNotification()
                }
                ACTION_STOP -> stopCleanly()
                else -> if (!engine.isRunning) stopSelf()
            }
        } catch (t: Throwable) {
            // Crash-safe (A-01): a start/stop failure must never take the
            // process down with the FGS still marked active.
            EventsBus.events.error("SERVICE_ERROR", t.message ?: "service command failed")
            stopCleanly()
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTaskRemoved(rootIntent: Intent?) {
        // User swiped the app away mid-session — stop instead of leaving a
        // zombie capture (A-01 crash-safe).
        stopCleanly()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        overlay.detach()
        OverlayBus.controller = null
        if (engine.isRunning) engine.stop()
        EventsBus.engine = null
        super.onDestroy()
    }

    private fun stopCleanly() {
        Breadcrumbs.mark("service.stop", "running=${engine.isRunning}")
        try {
            engine.stop()
        } catch (_: Throwable) {}
        overlay.detach()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun startAsForeground() = updateForegroundNotification()

    /** Rebuilds the FGS notification (G-03: pause/resume + stop actions). */
    private fun updateForegroundNotification() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Live translation", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val pausedNow = engine.isPaused
        val toggle = Intent(this, CaptureService::class.java).apply {
            action = if (pausedNow) ACTION_RESUME else ACTION_PAUSE
        }
        val stop = Intent(this, CaptureService::class.java).apply { action = ACTION_STOP }
        val cycleLang = Intent(this, CaptureService::class.java).apply { action = ACTION_CYCLE_LANG }
        val pendingFlag = android.app.PendingIntent.FLAG_UPDATE_CURRENT or
            android.app.PendingIntent.FLAG_IMMUTABLE
        val langLabel = languageLabel(engine.currentSrcLang)
        val notification: Notification = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("LiveLens · $langLabel → English")
            .setContentText(
                when {
                    pausedNow -> "Paused — tap resume to continue"
                    silenceHinting -> "Still listening? No speech detected in a while"
                    else -> "Translating on-device audio"
                },
            )
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(
                0,
                if (pausedNow) "Resume" else "Pause",
                android.app.PendingIntent.getService(this, 1, toggle, pendingFlag),
            )
            .addAction(
                0,
                "Lang: $langLabel",
                android.app.PendingIntent.getService(this, 3, cycleLang, pendingFlag),
            )
            .addAction(
                0,
                "Stop",
                android.app.PendingIntent.getService(this, 2, stop, pendingFlag),
            )
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val type = if (engine.captureMode == CaptureEngine.CaptureMode.MIC) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            } else {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            }
            startForeground(NOTIFICATION_ID, notification, type)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    companion object {
        const val ACTION_START = "dev.livelens.action.START"
        const val ACTION_PAUSE = "dev.livelens.action.PAUSE"
        const val ACTION_RESUME = "dev.livelens.action.RESUME"
        const val ACTION_STOP = "dev.livelens.action.STOP"
        const val ACTION_CYCLE_LANG = "dev.livelens.action.CYCLE_LANG"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"
        const val EXTRA_SESSION_ID = "sessionId"
        const val EXTRA_SRC_LANG = "srcLang"
        const val EXTRA_TASK = "task"
        const val EXTRA_MIC_MODE = "micMode"
        private const val CHANNEL_ID = "livelens_capture"
        private const val NOTIFICATION_ID = 42

        /**
         * Source languages offered by the notification "Lang:" action.
         * Auto first (F-01 default), then the common live-audio targets.
         */
        val LANG_CYCLE = listOf("auto", "ja", "en", "zh", "ko")
        private val LANG_LABELS = mapOf(
            "auto" to "Auto",
            "ja" to "日本語",
            "en" to "English",
            "zh" to "中文",
            "ko" to "한국어",
        )

        /** Next language in the cycle after [current]. Unknown → "auto". */
        fun nextLanguage(current: String): String {
            val idx = LANG_CYCLE.indexOf(current)
            return LANG_CYCLE[(idx + 1).mod(LANG_CYCLE.size)]
        }

        /** Human label for a source-language code. */
        fun languageLabel(code: String): String = LANG_LABELS[code] ?: code

        fun startIntent(
            context: Context,
            resultCode: Int,
            data: Intent,
            sessionId: String,
            srcLang: String?,
            task: String = "translate",
            micMode: Boolean = false,
        ) = Intent(context, CaptureService::class.java).apply {
            action = ACTION_START
            putExtra(EXTRA_RESULT_CODE, resultCode)
            putExtra(EXTRA_RESULT_DATA, data)
            putExtra(EXTRA_SESSION_ID, sessionId)
            putExtra(EXTRA_SRC_LANG, srcLang)
            putExtra(EXTRA_TASK, task)
            putExtra(EXTRA_MIC_MODE, micMode)
        }
    }
}

/** Process-wide channel so MainActivity ↔ CaptureService share one emitter. */
object EventsBus {
    val events = EventEmitter()
    var engine: CaptureEngine? = null
}
