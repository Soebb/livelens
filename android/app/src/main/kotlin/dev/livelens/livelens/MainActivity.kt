package dev.livelens.livelens

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import dev.livelens.livelens.core.Breadcrumbs
import dev.livelens.livelens.core.EventEmitter
import dev.livelens.livelens.core.ModelBenchmark
import dev.livelens.livelens.core.ModelCatalog
import dev.livelens.livelens.core.ModelDownloadManager
import dev.livelens.livelens.core.ModelRegistry
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CONTROL_CHANNEL,
        ).setMethodCallHandler { call, result ->
            try {
                handleControl(call.method, call.arguments, result)
            } catch (t: Throwable) {
                result.error("NATIVE_ERROR", t.message ?: "unhandled", null)
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                    // dispatch on the main thread (EventSink requirement)
                    EventsBus.events.attach(object : EventEmitter.Sink {
                        override fun success(event: Any?) {
                            mainHandler.post { sink.success(event) }
                        }
                    })
                }

                override fun onCancel(args: Any?) = EventsBus.events.detach()
            })

        // Additive channel (§3 set stays frozen): model download progress.
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, MODEL_EVENTS_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                    ModelDownloadManager.listener = { progress ->
                        mainHandler.post { sink.success(progress.toWire()) }
                    }
                }

                override fun onCancel(args: Any?) {
                    ModelDownloadManager.listener = null
                }
            })

        // E-01/E-03 startup warm-up: materialize + hot-load the bundled
        // default engine in the background so sessions and the benchmark
        // never run against NoopTranscriber (which swallows all audio and
        // made real-device sessions capture nothing). Failures are surfaced
        // through getCapabilities (installed/downloadState) — the Models
        // screen offers retries.
        Thread {
            try {
                if (!ModelRegistry.isLoaded) {
                    val bundled = ModelCatalog.all.first { it.bundled }
                    ModelRegistry.load(this@MainActivity, bundled.id)
                    // Push a `done` model event so the Dart side re-reads
                    // capabilities — the Dashboard's "no model loaded" text
                    // otherwise stays stale until the next screen visit
                    // (initState only fires once per navigation).
                    ModelDownloadManager.listener?.invoke(
                        ModelDownloadManager.Progress(
                            modelId = bundled.id,
                            status = ModelDownloadManager.Status.DONE,
                            bytesDone = bundled.totalBytes,
                            bytesTotal = bundled.totalBytes,
                        ),
                    )
                }
            } catch (t: Throwable) {
                // Non-fatal: NoopTranscriber keeps sessions honest-but-empty.
                // The reason is recorded by ModelRegistry breadcrumbs; also
                // stamp the warm-up entry point so Diagnostics shows it.
                Breadcrumbs.mark(
                    "model.warmup.fail",
                    "${t.javaClass.simpleName}: ${t.message}",
                )
            }
        }.start()
    }

    private fun handleControl(method: String, arguments: Any?, result: MethodChannel.Result) {
        val args = arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        when (method) {
            "startSession" -> {
                val sessionId = args["sessionId"] as? String ?: ""
                if (sessionId.isEmpty()) {
                    result.error("INVALID_ARGUMENT", "sessionId required", null)
                    return
                }
                val srcLang = args["sourceLang"] as? String
                val task = args["taskId"] as? String ?: "translate"
                // A-05 deviation (documented): mode="mic" bypasses the
                // projection consent flow entirely and starts the service
                // with RECORD_AUDIO runtime-permission enforcement here.
                if (args["mode"] as? String == "mic") {
                    pendingMicStart = MicStart(sessionId, srcLang, task)
                    if (hasMicPermission()) {
                        beginMicSession()
                    } else {
                        requestPermissions(arrayOf(android.Manifest.permission.RECORD_AUDIO), REQUEST_MIC)
                    }
                } else {
                    val intent = Intent(this, ProjectionActivity::class.java).apply {
                        putExtra(ProjectionActivity.EXTRA_SESSION_ID, sessionId)
                        putExtra(ProjectionActivity.EXTRA_SRC_LANG, srcLang)
                        putExtra(ProjectionActivity.EXTRA_TASK, task)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(intent)
                }
                result.success(null)
            }
            "pause" -> {
                val engine = EventsBus.engine
                if (engine == null) {
                    result.error("NOT_RUNNING", "no active session", null)
                } else {
                    engine.pause()
                    result.success(null)
                }
            }
            "resume" -> {
                val engine = EventsBus.engine
                if (engine == null) {
                    result.error("NOT_RUNNING", "no active session", null)
                } else {
                    engine.resume()
                    result.success(null)
                }
            }
            "stopSession" -> {
                val engine = EventsBus.engine
                if (engine == null) {
                    result.success(0)
                } else {
                    startService(intentFor(CaptureService.ACTION_STOP))
                    result.success(engine.elapsedLiveMsCompat())
                }
            }
            "setGovernorPrefs" -> {
                GovernorPrefsStore.save(this, args)
                result.success(null)
            }
            else -> handleControlRest(method, args, result)
        }
    }

    private fun handleControlRest(method: String, args: Map<*, *>, result: MethodChannel.Result) {
        when (method) {
            "getCapabilities" -> result.success(
                // Contract §2.2 frozen shape (additive extras tolerated):
                // {activeModelId, downloadPath, availableModels:[ModelInfo]}.
                mapOf(
                    "activeModelId" to ModelRegistry.loadedModelId,
                    "downloadPath" to
                        java.io.File(filesDir, "models").absolutePath,
                    "availableModels" to ModelRegistry.availableModels(this),
                    // Additive diagnostics beyond the frozen keys:
                    "sdkInt" to Build.VERSION.SDK_INT,
                    "device" to Build.MODEL,
                    "playbackCapture" to (Build.VERSION.SDK_INT >= 29),
                    "deviceTotalRamMb" to ModelRegistry.deviceTotalRamMb(this),
                ),
            )
            "loadModel" -> {
                // E-01/E-04: catalog-aware hot-load/hot-swap. Asset copy +
                // ONNX session init take seconds, so load off the main
                // thread and deliver on it (MethodChannel.Result must be
                // answered on the platform thread).
                val modelId = args["modelId"] as? String ?: ""
                if (ModelCatalog.byId(modelId) == null) {
                    result.error("MODEL_MISSING", "unknown model: $modelId", null)
                } else if (ModelRegistry.loadedModelId == modelId) {
                    result.success(null) // idempotent re-load
                } else {
                    Thread {
                        try {
                            ModelRegistry.load(applicationContext, modelId)
                            mainHandler.post { result.success(null) }
                        } catch (t: IllegalArgumentException) {
                            mainHandler.post {
                                result.error("MODEL_MISSING", t.message ?: "model missing", null)
                            }
                        } catch (t: IllegalStateException) {
                            // Not-installed maps to MODEL_MISSING; the RAM
                            // gate (E-01 quality tier) surfaces in the detail.
                            val code =
                                if (t.message?.startsWith("model not installed") == true) {
                                    "MODEL_MISSING"
                                } else {
                                    "MODEL_LOAD_FAILED"
                                }
                            mainHandler.post {
                                result.error(code, t.message ?: "load failed", null)
                            }
                        } catch (t: Throwable) {
                            mainHandler.post {
                                result.error(
                                    "MODEL_LOAD_FAILED",
                                    t.message ?: "load failed",
                                    null,
                                )
                            }
                        }
                    }.start()
                }
            }
            "requestOverlayPermission" -> {
                if (Settings.canDrawOverlays(this)) {
                    result.success(true)
                } else {
                    startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:$packageName"),
                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    result.success(false)
                }
            }
            "isBatteryExemptionGranted" -> {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                result.success(pm.isIgnoringBatteryOptimizations(packageName))
            }
            "performCompatCheck" -> result.success(compatCheckEntries())
            "openBatterySettings" -> {
                // G-02 battery-exemption helper: Settings screen needs no
                // special permission (unlike the direct-opt-in dialog).
                startActivity(
                    Intent(android.provider.Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                result.success(null)
            }
            "setOverlayStyle" -> {
                // §2.4: parse + persist + apply live to a running overlay;
                // safe when idle (no overlay attached → just cached).
                OverlayStore.apply(this, OverlayStyle.fromWire(args))
                result.success(null)
            }
            "saveOverlayPosition" -> {
                // §2.4: persisted by native; Dart throttles ≤ 1 call / 500 ms.
                fun px(k: String) = (args[k] as? Number)?.toInt() ?: 0
                OverlayStore.savePosition(
                    this,
                    OverlayPosition(px("x"), px("y"), px("w"), px("h")),
                )
                result.success(null)
            }
            "unloadModel" -> {
                // E-04 counterpart: frees ONNX memory; re-loadable any time.
                ModelRegistry.unload()
                result.success(null)
            }
            "downloadModel" -> {
                // E-02: start (or resume). Progress streams on the additive
                // livelens/model_events channel; true only when the transfer
                // actually started.
                val modelId = args["modelId"] as? String ?: ""
                when {
                    ModelCatalog.byId(modelId) == null ->
                        result.error("MODEL_MISSING", "unknown model: $modelId", null)
                    ModelDownloadManager.start(applicationContext, modelId) ->
                        result.success(true)
                    // Bundled (nothing to download) or another download is
                    // already running; Dart re-reads the capability state.
                    else -> result.success(false)
                }
            }
            "pauseModelDownload" -> {
                ModelDownloadManager.pause(args["modelId"] as? String ?: "")
                result.success(null)
            }
            "cancelModelDownload" -> {
                ModelDownloadManager.cancel(applicationContext, args["modelId"] as? String ?: "")
                result.success(null)
            }
            "getCrashLog" -> result.success(
                runCatching {
                    val crash = java.io.File(filesDir, LivelensApplication.CRASH_FILE)
                        .takeIf { it.isFile }?.readText().orEmpty()
                    val journal = Breadcrumbs.readAll(this)
                    buildString {
                        append("=== crash-log.txt ===\n")
                        append(crash.ifEmpty { "(empty — no uncaught Java exception recorded)\n" })
                        append("\n=== diagnostics-log.txt (breadcrumbs) ===\n")
                        append(journal.ifEmpty { "(empty — no breadcrumbs recorded)\n" })
                    }.take(96_000)
                }.getOrDefault(""),
            )
            "runBenchmark" -> {
                // E-03: scripted harness against the live engine. Refuses
                // during a session (the recognizer is thread-confined).
                if (!ModelRegistry.isLoaded) {
                    result.error("MODEL_MISSING", "no model loaded", null)
                } else if (EventsBus.engine != null) {
                    result.error(
                        "INVALID_ARGUMENT",
                        "stop the active session before benchmarking",
                        null,
                    )
                } else {
                    val rounds = (args["rounds"] as? Number)?.toInt()
                        ?: ModelBenchmark.DEFAULT_ROUNDS
                    val transcriber = ModelRegistry.transcriber
                    Thread {
                        try {
                            val metrics = ModelBenchmark.run(transcriber, rounds)
                            mainHandler.post { result.success(metrics) }
                        } catch (t: Throwable) {
                            mainHandler.post {
                                result.error(
                                    "INTERNAL_ERROR",
                                    t.message ?: "benchmark failed",
                                    null,
                                )
                            }
                        }
                    }.start()
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun intentFor(action: String) =
        Intent(this, CaptureService::class.java).apply { this.action = action }

    // ---------------------------------------------------------------- //
    // A-05 mic fallback plumbing

    private data class MicStart(val sessionId: String, val srcLang: String?, val task: String)

    private var pendingMicStart: MicStart? = null

    private fun hasMicPermission(): Boolean =
        checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED

    private fun beginMicSession() {
        val start = pendingMicStart ?: return
        pendingMicStart = null
        startForegroundService(
            CaptureService.startIntent(
                this, 0, Intent(), start.sessionId, start.srcLang,
                task = start.task, micMode = true,
            ),
        )
        // Reuse the Dart FSM's granted transition (documented deviation):
        // for mic mode there is no consent dialog; "granted" means
        // permission OK + service started, and the overlay shows the
        // degraded-mode badge.
        EventsBus.events.projectionGranted()
    }

    @Deprecated("Deprecated in Java")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_MIC) return
        if (grantResults.isNotEmpty() &&
            grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            beginMicSession()
        } else {
            pendingMicStart = null
            EventsBus.events.error("AUDIO_RECORD_FAILED", "microphone permission denied")
        }
    }

    /** G-02 pre-flight entries in the contract §2.3 wire shape. */
    private fun compatCheckEntries(): List<Map<String, Any?>> {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        val checks = listOf(
            Triple("sdk", Build.VERSION.SDK_INT >= 29, "playback capture needs API 29+"),
            Triple(
                "overlay",
                Settings.canDrawOverlays(this),
                "overlay permission (Settings deep-link)",
            ),
            Triple(
                "notifications",
                Build.VERSION.SDK_INT < 33 ||
                    checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
                    android.content.pm.PackageManager.PERMISSION_GRANTED,
                "session notification visibility",
            ),
            Triple(
                "battery",
                pm.isIgnoringBatteryOptimizations(packageName),
                "battery-optimization exemption (OEM guide)",
            ),
            Triple(
                "mic",
                hasMicPermission(),
                "mic fallback (degraded mode)",
            ),
            Triple(
                "model",
                ModelRegistry.isLoaded,
                "whisper-base loaded",
            ),
        )
        return checks.map { (pkg, ok, label) ->
            mapOf(
                "pkg" to pkg,
                "label" to label,
                "capturableLikely" to ok,
            )
        }
    }

    companion object {
        const val CONTROL_CHANNEL = "livelens/control"
        const val EVENTS_CHANNEL = "livelens/events"

        /** Additive (E-02): model download progress — §3 event set stays frozen. */
        const val MODEL_EVENTS_CHANNEL = "livelens/model_events"
        private const val REQUEST_MIC = 9101
    }
}

/** Governor prefs last-writer-wins store; unknown keys tolerated (§2.3). */
object GovernorPrefsStore {
    @Volatile var last: Map<*, *> = emptyMap<Any, Any>()

    fun save(context: Context, prefs: Map<*, *>) {
        last = prefs
        context.getSharedPreferences("livelens_prefs", Context.MODE_PRIVATE)
            .edit()
            .putString("governor_prefs_json", prefs.entries.joinToString(";") { "${it.key}=${it.value}" })
            .apply()
    }
}



