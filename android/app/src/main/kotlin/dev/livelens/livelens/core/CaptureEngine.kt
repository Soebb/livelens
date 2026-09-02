package dev.livelens.livelens.core

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import dev.livelens.livelens.GovernorPrefsStore
import android.os.BatteryManager
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Live capture engine (B-01/B-05 pipeline wiring, architecture §3.2).
 *
 * Threads:
 * - capture thread: AudioRecord.read → PcmRingBuffer (drop-oldest)
 * - pipeline thread: ring -> 16 kHz resample -> Silero VAD (B-02) ->
 *   UtteranceSplitter (B-03) -> bounded inference queue (B-04) ->
 *   final events + SegmentSpool
 *
 * Pause semantics (B-08): capture keeps draining hardware but audio is
 * discarded and the session clock excludes the paused span; resume clears
 * the ring so no pre-pause audio leaks into post-resume output.
 */
class CaptureEngine(
    context: Context,
    private val events: EventEmitter,
    private val spoolFile: File,
) {
    /**
     * Engine provider, read per decode so a hot-swap (E-04) takes effect
     * mid-session without a service restart. CaptureService wires this to
     * [ModelRegistry.transcriber]; tests may inject fakes.
     */
    var transcriberProvider: () -> Transcriber = { NoopTranscriber() }

    /** A-05: mic fallback when playback capture is blocked by the target app. */
    enum class CaptureMode { PROJECTION, MIC }

    @Volatile var captureMode = CaptureMode.PROJECTION

    /**
     * §3.7 silence guard: fired with `true` after ~10 min without any
     * recognized utterance (persistent-notification nudge), `false` again
     * on the next utterance. Called from the pipeline thread.
     */
    @Volatile var onSilenceHint: ((Boolean) -> Unit)? = null

    /**
     * Epic 4: finalized segment forwarded to the native overlay
     * (src = model text, en = translation). Called from the inference
     * thread. Additive — hosts may ignore.
     */
    @Volatile var onOverlayText: ((src: String, en: String) -> Unit)? = null

    /**
     * Epic 4 overlay status chip: "paused" (manual/overload),
     * "thermal" (cooling down), "battery" (low-battery mode), or null
     * to clear. Additive — hosts may ignore.
     */
    @Volatile var onOverlayChip: ((String?) -> Unit)? = null

    private val appContext = context.applicationContext
    private val running = AtomicBoolean(false)
    private val paused = AtomicBoolean(false)
    private val executor = Executors.newFixedThreadPool(2)
    private val clock = SessionClock()
    private var governor = Governor()
    private val timeline = ChunkTimeline()
    private val silence = SilenceWatch()

    /** Rebuilt per session so prefs-sourced queue depth applies. */
    private var inference = InferenceExecutor()
    private var queueCapacity = InferenceExecutor.QUEUE_CAPACITY

    @Volatile private var governorPaused = false
    @Volatile private var hinting = false

    @Volatile private var projection: MediaProjection? = null
    @Volatile private var record: AudioRecord? = null
    @Volatile private var sessionId: String = ""
    @Volatile private var srcLang: String = "auto"
    @Volatile private var task: String = "translate"
    @Volatile private var stopLatch: CountDownLatch? = null

    /** F-03 auto-detect guardrail (majority vote over recent utterances). */
    private val langSmoother = LangSmoother()

    /**
     * B-04b hallucination guard, evaluated per finalized segment. Until its
     * wiring (this field), the class existed but no engine referenced it —
     * the root cause of unbounded repetition loops on auto-language audio.
     */
    private val hallucination = HallucinationGuard()

    /**
     * Overload-pause auto-recovery: when the governor pauses for
     * QUEUE_OVERLOAD it used to latch forever (manual resume required).
     * After this cooldown with the queue drained, the session auto-resumes.
     */
    @Volatile private var overloadPausedAtMs = -1L

    // VAD worker is created (and confined) on the pipeline thread
    @Volatile private var vad: VadWorker? = null

    private var segCounter = 0

    /** Breadcrumb once per session: the first decode attempt. */
    @Volatile private var firstDecodeDone = false

    val isRunning: Boolean get() = running.get()
    val isPaused: Boolean get() = paused.get()

    /** Live elapsed session time for stopSession replies (B-08). */
    fun elapsedLiveMsCompat(): Long = clock.elapsedLiveMs()

    /** Current forced source language ("auto" while auto-detecting). */
    val currentSrcLang: String get() = srcLang

    /**
     * Mid-session source-language switch (notification / overlay actions).
     * Applies from the next decode — [SherpaWhisperTranscriber] rebuilds its
     * config whenever the language changes. null/"auto"/blank → auto-detect.
     */
    fun setSourceLanguage(lang: String?) {
        val next = lang?.takeIf { it.isNotBlank() && it != "auto" } ?: "auto"
        if (next != srcLang) {
            srcLang = next
            langSmoother.reset()
            Breadcrumbs.mark("engine.src_lang", next)
        }
    }

    // ------------------------------------------------------------------ //

    fun start(
        projectionResult: Int,
        projectionData: Intent,
        sessionId: String,
        srcLang: String?,
        task: String = "translate",
    ) {
        if (!running.compareAndSet(false, true)) return
        this.sessionId = sessionId
        this.srcLang = srcLang ?: "auto"
        this.task = task
        this.paused.set(false)
        segCounter = 0
        firstDecodeDone = false
        silence.reset()
        langSmoother.reset()
        hallucination.reset()
        overloadPausedAtMs = -1L

        // A-05: mic fallback needs no projection; playback capture does.
        if (captureMode == CaptureMode.PROJECTION) {
            val mgr = appContext.getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                as android.media.projection.MediaProjectionManager
            projection = mgr.getMediaProjection(projectionResult, projectionData)?.also { p ->
                p.registerCallback(object : MediaProjection.Callback() {
                    override fun onStop() {
                        // user revoked via the system cast tile — stop cleanly
                        events.error("CAPTURE_REVOKED", "Media projection revoked")
                        stop()
                    }
                }, null)
            }
            if (projection == null) {
                running.set(false)
                events.error("PROJECTION_DENIED", "getMediaProjection returned null")
                return
            }
        }

        applyPrefs()
        clock.start()
        Breadcrumbs.mark(
            "session.begin",
            "id=$sessionId mode=$captureMode task=$task src=$srcLang " +
                "engineLoaded=${ModelRegistry.isLoaded}",
        )
        events.state("capturing")
        startThreads()
    }


    private fun startThreads() {
        val captureRate = 48_000
        val channels = AudioFormat.CHANNEL_IN_MONO
        val encoding = AudioFormat.ENCODING_PCM_16BIT
        val minBuf = AudioRecord.getMinBufferSize(captureRate, channels, encoding)
        val format = AudioFormat.Builder()
            .setSampleRate(captureRate).setChannelMask(channels).setEncoding(encoding)
            .build()

        val rec = try {
            when (captureMode) {
                // A-05 mic fallback: RECORD_AUDIO runtime permission is
                // checked by MainActivity before startSession(micFallback).
                CaptureMode.MIC -> AudioRecord.Builder()
                    .setAudioSource(android.media.MediaRecorder.AudioSource.MIC)
                    .setAudioFormat(format)
                    .setBufferSizeInBytes(minBuf * 2)
                    .build()
                // A-03: playback capture filtered to {MEDIA, GAME, UNKNOWN}
                CaptureMode.PROJECTION -> AudioRecord.Builder()
                    .setAudioFormat(format)
                    .setBufferSizeInBytes(minBuf * 2)
                    .setAudioPlaybackCaptureConfig(
                        AudioPlaybackCaptureConfiguration.Builder(projection!!)
                            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                            .addMatchingUsage(AudioAttributes.USAGE_GAME)
                            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                            .build(),
                    )
                    .build()
            }
        } catch (t: Throwable) {
            running.set(false)
            events.error(
                if (captureMode == CaptureMode.MIC) "AUDIO_RECORD_FAILED" else "CAPTURE_INIT_FAILED",
                t.message ?: "AudioRecord init failed",
            )
            return
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            running.set(false)
            rec.release()
            events.error(
                if (captureMode == CaptureMode.MIC) "AUDIO_RECORD_FAILED" else "CAPTURE_INIT_FAILED",
                "AudioRecord not initialized (permission/blocking app?)",
            )
            return
        }
        record = rec
        val ring = PcmRingBuffer(captureRate * 10) // ~10 s headroom at 48 kHz
        val resampler = LinearResampler(captureRate)

        executor.execute {
            try {
                rec.startRecording()
                val chunk = ShortArray(2048)
                while (running.get()) {
                    val n = rec.read(chunk, 0, chunk.size)
                    if (n > 0 && !paused.get()) ring.write(chunk, 0, n)
                    // while paused: drain hardware, discard (B-08)
                }
            } catch (t: Throwable) {
                events.error("CAPTURE_INIT_FAILED", t.message ?: "capture thread failed")
            } finally {
                try { rec.stop() } catch (_: Throwable) {}
                rec.release()
            }
        }

        executor.execute {
            var worker: VadWorker? = null
            try {
                // B-04: single-slot inference thread with bounded queue;
                // model hot-load happens as its warm-up step.
                Breadcrumbs.mark("pipeline.begin", "session=$sessionId")
                inference.start(
                    warmUp = { transcriberProvider().warmUp() },
                    decode = { decodeChunk(it) },
                )
                // VAD init failure must not kill the process (a JNI abort
                // here leaves no Java crash trace); degrade to a visible
                // error event + clean stop instead.
                try {
                    worker = VadWorker.create(appContext).also { vad = it }
                } catch (t: Throwable) {
                    Breadcrumbs.mark(
                        "vad.create.fail",
                        "${t.javaClass.simpleName}: ${t.message}",
                    )
                    running.set(false)
                    events.error("VAD_INIT_FAILED", t.message ?: "voice-activity init failed")
                    return@execute
                }
                val splitter = UtteranceSplitter()
                var hopsSinceGovernorTick = 0
                var idleHops = 0
                while (running.get()) {
                    val raw = ring.read(captureRate / 4) // 250 ms hop
                    if (raw == null) {
                        Thread.sleep(40)
                        // §3.7: nothing recognized for ~10 min → one nudge
                        if (!paused.get() && silence.shouldHint()) {
                            hinting = true
                            onSilenceHint?.invoke(true)
                        }
                        // Ambient maintenance while idle/paused (~1 s cadence).
                        // The governor tick previously only ran when audio
                        // flowed, so RESUME_FROM_THERMAL could never fire once
                        // the session had paused — a silent-stall contributor.
                        if (++idleHops >= 25) {
                            idleHops = 0
                            ambientMaintenance()
                        }
                        continue
                    }
                    val pcm16k = resampler.process(raw)
                    if (pcm16k.isEmpty()) continue
                    val origin = elapsedSessionMs() - pcm16k.size / 16.0
                    // B-02: Silero VAD assembles padded utterances
                    val utterances = worker!!.accept(pcm16k, origin)
                    if (utterances.isNotEmpty()) {
                        silence.onSpeech()
                        if (hinting) {
                            hinting = false
                            onSilenceHint?.invoke(false)
                        }
                    }
                    for (utterance in utterances) {
                        for (chunk16k in splitter.split(utterance)) {
                            if (!inference.submit(chunk16k)) {
                                events.error("QUEUE_OVERLOAD_PAUSED", "inference queue full; chunk dropped")
                            }
                        }
                    }
                    // §3.7 rows 2–3, 5: thermal/battery/screen tick ~every 30 s
                    if (++hopsSinceGovernorTick >= GOVERNOR_TICK_HOPS) {
                        hopsSinceGovernorTick = 0
                        applyGovernorTick()
                    }
                }
            } catch (t: Throwable) {
                if (running.get()) events.error("INTERNAL_ERROR", t.message ?: "pipeline failed")
            } finally {
                // shutdown-drain: finish queued utterances before exiting (B-04)
                try {
                    worker?.flush()?.let { utterances ->
                        val splitter = UtteranceSplitter()
                        for (utterance in utterances) {
                            for (chunk16k in splitter.split(utterance)) inference.submit(chunk16k)
                        }
                    }
                } catch (_: Throwable) {}
                inference.shutdownDrain()
                worker?.close()
                vad = null
            }
        }
    }

    fun pause() {
        if (!running.get() || !paused.compareAndSet(false, true)) return
        governorPaused = false // a manual pause overrides any governor latch
        overloadPausedAtMs = -1L
        clock.pause()
        events.state("paused")
        onOverlayChip?.invoke("paused")
    }

    fun resume() {
        if (!running.get() || !paused.compareAndSet(true, false)) return
        overloadPausedAtMs = -1L
        clock.resume()
        events.state("capturing")
        onOverlayChip?.invoke(null)
    }

    private fun pauseByGovernor(cause: String) {
        if (!paused.get()) pause() // clears any stale latch via pause()
        governorPaused = true
        onOverlayChip?.invoke(cause)
    }

    /**
     * Idle-path maintenance (~1 s cadence while no audio is flowing):
     * governor ambient inputs still evaluate (so thermal auto-resume works
     * while paused), and overload pauses auto-resume after their cooldown
     * instead of latching until a manual resume.
     */
    private fun ambientMaintenance() {
        val now = System.currentTimeMillis()
        if (governorPaused && overloadPausedAtMs > 0 &&
            now - overloadPausedAtMs >= OVERLOAD_RESUME_COOLDOWN_MS
        ) {
            overloadPausedAtMs = -1L
            Breadcrumbs.mark("governor.auto_resume", "overload cooldown elapsed")
            if (paused.get()) resume()
            governorPaused = false
        }
        if (running.get()) applyGovernorTick()
    }

    /** Stops capture, finalizes the clock, flushes. Blocks = 2 s (B-08). */
    fun stop(): Long {
        if (!running.compareAndSet(true, false)) return 0
        val latch = CountDownLatch(1)
        stopLatch = latch
        executor.execute { latch.countDown() }
        latch.await(2, TimeUnit.SECONDS)
        val live = clock.stop()
        try { projection?.stop() } catch (_: Throwable) {}
        projection = null
        record = null
        val spool = SegmentSpool(spoolFile)
        val pendingCount = spool.pendingCount()
        if (pendingCount > 0) events.spoolPending(pendingCount)
        events.state("stopped")
        return live
    }

    // ------------------------------------------------------------------ //

    /** Session-relative ms (excludes paused spans — B-08). */
    private fun elapsedSessionMs(): Double = clock.elapsedLiveMs().toDouble()

    /**
     * Session-start configuration from setGovernorPrefs (contract §2.2):
     * unknown/absent keys keep defaults.
     */
    private fun applyPrefs() {
        val prefs = GovernorPrefsStore.last
        fun bool(k: String, d: Boolean) = (prefs[k] as? Boolean) ?: d
        fun num(k: String, d: Int) = when (val v = prefs[k]) {
            is Int -> v; is Double -> v.toInt(); else -> d
        }
        governor = Governor(
            Governor.Prefs(
                screenOffAutoPause = bool("screenOffAutoPause", false),
                batteryLowThresholdPct = num("batteryLowThresholdPct", 15),
                thermalHysteresisMs = num("thermalHysteresisMs", 60_000).toLong(),
            ),
        )
        val depth = num("inferenceQueueDepth", InferenceExecutor.QUEUE_CAPACITY)
        queueCapacity = depth.coerceIn(1, 8)
        inference = InferenceExecutor(capacity = queueCapacity)
    }

    /**
     * Ambient-input governor tick (~30 s): thermal status, battery, screen
     * state (§3.7 rows 2–3, 5). RTF/queue policy stays per-chunk.
     */
    private fun applyGovernorTick() {
        val pm = appContext.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
        val bm = appContext.getSystemService(Context.BATTERY_SERVICE) as android.os.BatteryManager
        val batteryPct = bm.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY)
            .coerceIn(0, 100).toDouble()
        handleDecision(
            governor.evaluate(
                Governor.Metrics(
                    rtf = 0.0,
                    queueDepth = inference.depth,
                    queueCapacity = queueCapacity,
                    thermalLevel = ThermalLevels.fromStatus(pm.currentThermalStatus),
                    batteryPct = batteryPct,
                    screenOn = pm.isInteractive,
                ),
            ),
        )
    }

    private fun decodeChunk(chunk: InferenceChunk) {
        if (!firstDecodeDone) {
            firstDecodeDone = true
            Breadcrumbs.mark(
                "decode.first",
                "engine=${transcriberProvider().javaClass.simpleName} " +
                    "samples=${chunk.samples.size}",
            )
        }
        val t0 = System.nanoTime()
        val transcription = transcriberProvider().decode(
            chunk,
            task = task,
            language = if (srcLang == "auto") "" else srcLang,
        )
        val decodeMs = (System.nanoTime() - t0) / 1_000_000.0

        // governor tick per chunk; thermal/battery sources land with Epic 2 finish
        val audioSec = chunk.samples.size / 16_000.0
        val decision = governor.evaluate(
            Governor.Metrics(
                rtf = if (audioSec <= 0) 0.0 else decodeMs / 1000.0 / audioSec,
                queueDepth = inference.depth,
                queueCapacity = queueCapacity,
            ),
        )
        handleDecision(decision)

        if (transcription.lines.isEmpty()) return

        // B-04b (1/2): collapse same-sentence echoes WITHIN one decode
        // result ("I feel like… I feel like… I feel like…" → one instance).
        // This is the first line of the hallucination-loop defense.
        val collapsed = transcription.lines
            .map { HallucinationGuard.collapseIntraRepetition(it) }
            .filter(String::isNotEmpty)
            .distinct()
        if (collapsed.isEmpty()) return

        // F-03: forced lang wins; else smoothed majority vote (short
        // utterances reuse the prior vote, confident ones join the window).
        val forced = if (srcLang == "auto") null else srcLang
        val utteranceMs = chunk.samples.size * 1000L / 16_000L
        val resolvedLang = langSmoother.resolve(utteranceMs, transcription.lang, forced)

        val timed = timeline.assignTimes(chunk, collapsed)
        for (ts in timed) {
            // B-04b (2/2): cross-chunk repetition ladder. Identical text
            // recurring across consecutive segments is the classic loop —
            // ≥ SUPPRESS_AFTER repeats are dropped (chip stays raised),
            // ≥ SUSPICIOUS_AFTER still emit but are flagged.
            val verdict = hallucination.evaluate(ts.text)
            if (verdict.verdict == HallucinationGuard.Verdict.SUPPRESS) {
                Breadcrumbs.mark(
                    "hallucination.suppress",
                    "repeats=${verdict.repetitionCount} text=${ts.text.take(40)}",
                )
                continue
            }
            val segId = "$sessionId-${segCounter++}"
            // Whisper-native translate emits only the English rendering —
            // the source text is mirrored until the MT cascade (B-04 note),
            // documented deviation, same storage rule as transcription mode.
            val src = ts.text
            val en = src
            events.final(sessionId, segId, ts.t0Ms, ts.t1Ms, resolvedLang, src, en, transcription.conf)
            onOverlayText?.invoke(src, en)
            SegmentSpool(spoolFile).append(
                SegmentSpool.SpooledSegment(
                    sessionId = sessionId, segId = segId,
                    t0Ms = ts.t0Ms, t1Ms = ts.t1Ms,
                    srcLang = resolvedLang, src = src, en = en, conf = transcription.conf,
                ),
            )
        }
    }

    /** Shared pause/resume policy application (per-chunk + ambient tick). */
    private fun handleDecision(decision: Governor.Decision) {
        when (decision.action) {
            Governor.Action.PAUSE_THERMAL -> {
                events.error("THERMAL_PAUSE", decision.reason)
                pauseByGovernor("thermal")
            }
            Governor.Action.PAUSE_BATTERY -> {
                events.error("BATTERY_PAUSE", decision.reason)
                pauseByGovernor("battery")
            }
            Governor.Action.PAUSE_OVERLOAD -> {
                events.error("QUEUE_OVERLOAD_PAUSED", decision.reason)
                Breadcrumbs.mark("governor.pause", "overload ${decision.reason}")
                overloadPausedAtMs = System.currentTimeMillis()
                pauseByGovernor("paused")
            }
            Governor.Action.PAUSE_SCREEN_OFF -> pauseByGovernor("paused")
            // §3.7: thermal hysteresis elapsed → automatic resume
            Governor.Action.RESUME_FROM_THERMAL -> {
                governorPaused = false
                if (paused.get()) resume()
            }
            else -> Unit
        }
    }

    companion object {
        /** 250 ms pipeline hop × 120 = ambient governor tick every ~30 s. */
        const val GOVERNOR_TICK_HOPS = 120

        /** Overload pauses auto-resume after this cooldown (B-04 stall fix). */
        const val OVERLOAD_RESUME_COOLDOWN_MS = 5_000L
    }
}
