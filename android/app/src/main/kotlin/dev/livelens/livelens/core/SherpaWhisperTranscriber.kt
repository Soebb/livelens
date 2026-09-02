package dev.livelens.livelens.core

import android.content.Context
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineWhisperModelConfig
import java.io.File

/**
 * sherpa-onnx Whisper engine over any [ModelCatalog] model directory
 * (architecture §3.4, contract §2.2 `loadModel`).
 *
 * For the bundled model the three files are copied once from APK assets
 * into `filesDir/models/<dir>/` (AAssetManager cannot memory-map the ~125 MB
 * compressed decoder reliably); downloaded models arrive there via
 * [ModelDownloadManager]. The copy is size-checked and skipped later.
 *
 * Task and language are applied per decode via `setConfig` (F-01/F-02);
 * `language=""` requests model-side auto-detect. sherpa-onnx does not
 * expose token probabilities for whisper, so [Transcription.conf] carries
 * the documented placeholder 0.9 (same value the pipeline used before
 * F-03; the per-segment *language* is the real signal being added).
 *
 * Thread-confined to the inference executor (§3.2 single mutex) per the
 * [Transcriber] contract: [warmUp] and [decode] must not be called
 * concurrently with each other or [close].
 */
class SherpaWhisperTranscriber private constructor(
    private val recognizer: OfflineRecognizer,
    private val encoderPath: String,
    private val decoderPath: String,
    private val tokensPath: String,
) : Transcriber {

    private var lastTask: String? = null
    private var lastLanguage: String? = null

    override fun warmUp() {
        // OfflineRecognizer constructor in [create] already loads the ONNX
        // sessions; a zero-cost stream round-trip forces lazy kernel init.
        val stream = recognizer.createStream()
        stream.acceptWaveform(FloatArray(SAMPLE_RATE / 10), SAMPLE_RATE)
        recognizer.decode(stream)
        stream.release()
    }

    override fun decode(chunk: InferenceChunk, task: String, language: String): Transcription {
        try {
            if (task != lastTask || language != lastLanguage) {
                recognizer.setConfig(config(task, language))
                lastTask = task
                lastLanguage = language
            }
            val stream = recognizer.createStream()
            try {
                val samples = FloatArray(chunk.samples.size) { chunk.samples[it] / 32768.0f }
                stream.acceptWaveform(samples, SAMPLE_RATE)
                recognizer.decode(stream)
                val result = recognizer.getResult(stream)
                val lines = result.text
                    .split('\n')
                    .map(String::trim)
                    .filter(String::isNotEmpty)
                    .distinct()
                val lang = result.lang.trim().lowercase()
                    .ifEmpty { language.ifEmpty { "auto" } }
                return Transcription(lines, lang, CONF_PLACEHOLDER)
            } finally {
                stream.release()
            }
        } catch (t: Throwable) {
            // Per Transcriber contract: never throw for ordinary decode failures.
            return Transcription(emptyList(), language.ifEmpty { "auto" }, 0.0)
        }
    }

    override fun close() {
        recognizer.release()
    }

    private fun config(task: String, language: String): OfflineRecognizerConfig =
        OfflineRecognizerConfig(
            modelConfig = OfflineModelConfig(
                whisper = OfflineWhisperModelConfig(
                    encoder = encoderPath,
                    decoder = decoderPath,
                    language = language,
                    task = task,
                ),
                tokens = tokensPath,
                numThreads = 4,
                modelType = "whisper",
            ),
        )

    companion object {
        const val SAMPLE_RATE = 16_000

        /** sherpa-onnx whisper exposes no token probabilities — honest placeholder. */
        const val CONF_PLACEHOLDER = 0.9

        private fun findFile(spec: ModelSpec, needle: String): String =
            spec.files.first { it.name.contains(needle) }.name

        /**
         * Materializes bundled assets (size-checked, idempotent) and builds
         * the recognizer for [spec] inside [dir]. Blocking — call off the
         * main thread.
         *
         * @throws IllegalStateException when expected files are missing
         *   (caller maps this to `MODEL_MISSING`/`MODEL_LOAD_FAILED`, §2.2).
         */
        fun create(context: Context, spec: ModelSpec, dir: File): SherpaWhisperTranscriber {
            val appContext = context.applicationContext
            dir.mkdirs()
            for (file in spec.files) {
                val out = File(dir, file.name)
                if (out.isFile && out.length() > 0L) continue
                val assetDir = spec.assetDir
                    ?: throw IllegalStateException("model not installed: ${spec.id}")
                appContext.assets.open("$assetDir/${file.name}").use { input ->
                    out.outputStream().use { output -> input.copyTo(output) }
                }
            }
            val encoder = File(dir, findFile(spec, "encoder")).absolutePath
            val decoder = File(dir, findFile(spec, "decoder")).absolutePath
            val tokens = File(dir, findFile(spec, "tokens")).absolutePath
            for (p in listOf(encoder, decoder, tokens)) {
                if (!File(p).isFile) {
                    throw IllegalStateException("model file missing: $p")
                }
            }
            val transcriber = SherpaWhisperTranscriber(
                recognizer = OfflineRecognizer(
                    config = OfflineRecognizerConfig(
                        modelConfig = OfflineModelConfig(
                            whisper = OfflineWhisperModelConfig(
                                encoder = encoder,
                                decoder = decoder,
                                language = "en",
                                task = "transcribe",
                                // Minimal tail padding — see config().
                                tailPaddings = 200,
                            ),
                            tokens = tokens,
                            numThreads = 4,
                            modelType = "whisper",
                        ),
                    ),
                ),
                encoderPath = encoder,
                decoderPath = decoder,
                tokensPath = tokens,
            )
            transcriber.lastTask = "transcribe"
            transcriber.lastLanguage = "en"
            return transcriber
        }
    }
}
