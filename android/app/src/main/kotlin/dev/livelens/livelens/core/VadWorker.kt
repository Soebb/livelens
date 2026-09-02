package dev.livelens.livelens.core

import android.content.Context
import com.k2fsa.sherpa.onnx.SileroVadModelConfig
import com.k2fsa.sherpa.onnx.Vad
import com.k2fsa.sherpa.onnx.VadModelConfig
import java.io.File
/**
 * One-shot utterance hand-off used by [VadWorker]: accumulates the
 * utterances produced during a single pipeline hop and hands them out
 * exactly once via [drainAll].
 *
 * Regression guard (2026-09 session): [VadWorker.accept] used to return a
 * never-cleared field, so every 250 ms hop re-submitted EVERY utterance
 * ever emitted. With the inference queue at capacity 2, the same two early
 * chunks were re-decoded forever (identical text every ~3 s, permanent
 * overload pauses, RTF pinned ~0.89, no live subtitles).
 */
internal class UtteranceHandOff {
    private val pending = ArrayList<Utterance>(2)

    fun add(utterance: Utterance) {
        pending += utterance
    }

    val isEmpty: Boolean
        get() = pending.isEmpty()

    /** Returns everything accumulated and clears the accumulation. */
    fun drainAll(): List<Utterance> =
        if (pending.isEmpty()) emptyList()
        else ArrayList(pending).also { pending.clear() }
}

/**
 * Silero VAD worker (B-02): sherpa-onnx VoiceActivityDetector framing at
 * 512 samples / 16 kHz, threshold 0.5, min speech 200 ms, hangover 350 ms
 * (via `minSilenceDuration`), 100 ms pad applied by [UtteranceAssembler].
 *
 * Latency behavior: while speech is ONGOING, buffered audio exceeding
 * [PARTIAL_EMIT_MS] is decoded immediately (minus a small primer tail kept
 * for continuity), so first subtitles arrive after ~5 s of speech instead
 * of waiting for the utterance to end. The eventual VAD segment then only
 * decodes the remainder.
 *
 * Thin sherpa-bound shell — all buffer/segment arithmetic lives in the
 * pure, unit-tested [UtteranceAssembler]. Thread-confined to the pipeline
 * thread, like the resampler.
 */
class VadWorker private constructor(private val vad: Vad) {

    private val assembler = UtteranceAssembler()

    /**
     * Feeds one contiguous 16 kHz block ([originMs] = session-timeline
     * origin of samples[0]) and returns utterances completed by it —
     * completed VAD segments plus mid-speech partial emits.
     */
    fun accept(samples: ShortArray, originMs: Double): List<Utterance> {
        assembler.feed(samples, originMs)
        vad.acceptWaveform(toFloats(samples))
        drain()
        if (vad.isSpeechDetected()) {
            // Speech still ongoing: flush everything past the primer tail
            // once it crosses the partial-decode threshold (latency).
            if (assembler.pendingMs() >= PARTIAL_EMIT_MS) {
                assembler.cutPartial(PARTIAL_KEEP_MS)?.let { handOff.add(it) }
            }
        } else {
            assembler.trimToPreRoll()
        }
        return handOff.drainAll()
    }

    /** End-of-stream: emits any trailing utterance still held by the VAD. */
    fun flush(): List<Utterance> {
        vad.flush()
        drain()
        return handOff.drainAll()
    }

    fun close() {
        runCatching { vad.release() }
    }

    private val handOff = UtteranceHandOff()

    private fun drain() {
        while (!vad.empty()) {
            val seg = vad.front()
            vad.pop()
            val end = seg.start.toLong() + seg.samples.size
            assembler.segment(seg.start.toLong(), end)?.let { handOff.add(it) }
        }
    }

    private fun toFloats(samples: ShortArray) =
        FloatArray(samples.size) { samples[it] / 32768.0f }

    companion object {
        const val MODEL_ID = "sherpa-onnx-silero-vad"
        const val ASSET_DIR = "flutter_assets/assets/sherpa-onnx-silero-vad"

        /**
         * Latency: while speech is ongoing, emit a partial decode once this
         * much audio is buffered (first subtitles after ~5 s of continuous
         * speech instead of waiting for the full utterance).
         */
        const val PARTIAL_EMIT_MS = 5_000.0

        /** Primer tail kept in the buffer across a partial emit (B-03 spec). */
        const val PARTIAL_KEEP_MS = 320.0
        // Suffix bumped from "models/silero-vad": the previously bundled
        // silero_vad.onnx was VAD v3, which sherpa-onnx v1.12.x does not
        // support (SileroVadModel::Init exits the process for non-v4/v5
        // models — SIGABRT, no Java exception). Versioning the directory
        // invalidates any stale v3 copy already materialized on devices.
        const val FILES_DIR_NAME = "models/silero-vad-v4"
        const val MODEL_FILE = "silero_vad.onnx"

        /** Copies the bundled model into filesDir if needed. Blocking. */
        fun materialize(context: Context): File {
            val appContext = context.applicationContext
            val dir = File(appContext.filesDir, FILES_DIR_NAME).apply { mkdirs() }
            val out = File(dir, MODEL_FILE)
            if (!out.isFile || out.length() == 0L) {
                appContext.assets.open("$ASSET_DIR/$MODEL_FILE").use { input ->
                    out.outputStream().use { output -> input.copyTo(output) }
                }
            }
            return out
        }

        /** Blocking (ONNX session init). Call off the main thread. */
        fun create(context: Context): VadWorker {
            Breadcrumbs.mark("vad.create.begin")
            val model = materialize(context)
            val vad = Vad(
                config = VadModelConfig(
                    sileroVadModelConfig = SileroVadModelConfig(
                        model = model.absolutePath,
                        threshold = 0.5f,
                        minSpeechDuration = 0.2f,
                        minSilenceDuration = 0.35f,
                        windowSize = 512,
                        // Forced VAD endpoint: long single utterances are the
                        // main first-decode latency AND hallucination-loop
                        // driver; the splitter caps decoded chunks at 8 s.
                        maxSpeechDuration = 8.0f,
                    ),
                    sampleRate = 16_000,
                    numThreads = 1,
                ),
            )
            Breadcrumbs.mark("vad.create.ok", "${model.length()} bytes @ ${model.path}")
            return VadWorker(vad)
        }
    }
}
