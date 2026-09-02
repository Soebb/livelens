package dev.livelens.livelens.core

/**
 * Curated model registry format (contract §2.2, PRD E-01).
 *
 * V1 ships exactly one bundled engine (whisper-base int8) plus two
 * on-demand downloads from the upstream sherpa-onnx HuggingFace repos:
 *
 *  - `fast`     → whisper tiny  int8 (~104 MB download)
 *  - `balanced` → whisper base  int8 (bundled in the APK)
 *  - `quality`  → whisper small int8 (~375 MB download, RAM-gated)
 *
 * Every downloadable file carries its upstream SHA-256 (verified after
 * download, before install). Bundled files live inside the signed APK so
 * their `sha256` is intentionally empty — integrity is delegated to the
 * APK signature and the size check at materialization time.
 */
data class ModelFileSpec(
    val name: String,
    val url: String,
    val sizeBytes: Long,
    /** Upstream SHA-256 hex digest; empty → skip verification (bundled only). */
    val sha256: String,
)

data class ModelSpec(
    val id: String,
    val label: String,
    /** `fast` | `balanced` | `quality` (contract §2.2 tier vocabulary). */
    val tier: String,
    /** True when the files ship inside the APK assets (no download). */
    val bundled: Boolean,
    /** Install directory name under `filesDir/models/`. */
    val dirName: String,
    /** `flutter_assets` sub-directory for bundled models; null when downloadable. */
    val assetDir: String?,
    val files: List<ModelFileSpec>,
    /** Supported Whisper tasks: subset of {transcribe, translate}. */
    val tasks: List<String>,
    /** ISO-639-1 source languages the model can transcribe (target is en, HT-3). */
    val languages: List<String>,
    /** Minimum device total RAM (MB) required to load this model. */
    val minTotalRamMb: Int,
) {
    val totalBytes: Long get() = files.sumOf { it.sizeBytes }
}

object ModelCatalog {

    /** Curated multilingual Whisper subset (Whisper itself supports ~99). */
    val WHISPER_LANGUAGES: List<String> = listOf(
        "en", "ja", "ko", "zh", "es", "fr", "de", "tr", "ru", "pt",
        "it", "ar", "hi", "id", "vi", "th", "nl", "pl", "uk", "sv",
        "da", "fi", "no", "cs", "el", "he", "ms", "fa", "ro", "hu",
    )

    private const val HF = "https://huggingface.co/csukuangfj"

    private val whisperTasks = listOf("transcribe", "translate")

    val all: List<ModelSpec> = listOf(
        ModelSpec(
            id = "sherpa-onnx-whisper-base",
            label = "Whisper Base (int8, built-in)",
            tier = "balanced",
            bundled = true,
            dirName = "whisper-base",
            assetDir = "flutter_assets/assets/sherpa-onnx-whisper-base",
            files = listOf(
                ModelFileSpec("base-encoder.int8.onnx", "$HF/sherpa-onnx-whisper-base/resolve/main/base-encoder.int8.onnx", 29_120_534L, ""),
                ModelFileSpec("base-decoder.int8.onnx", "$HF/sherpa-onnx-whisper-base/resolve/main/base-decoder.int8.onnx", 130_672_026L, ""),
                ModelFileSpec("base-tokens.txt", "$HF/sherpa-onnx-whisper-base/resolve/main/base-tokens.txt", 816_730L, ""),
            ),
            tasks = whisperTasks,
            languages = WHISPER_LANGUAGES,
            minTotalRamMb = 3000,
        ),
        ModelSpec(
            id = "sherpa-onnx-whisper-tiny",
            label = "Whisper Tiny (int8)",
            tier = "fast",
            bundled = false,
            dirName = "whisper-tiny",
            assetDir = null,
            files = listOf(
                // Sizes + SHA-256 from the upstream repo LFS manifest (API tree).
                ModelFileSpec(
                    "tiny-encoder.int8.onnx",
                    "$HF/sherpa-onnx-whisper-tiny/resolve/main/tiny-encoder.int8.onnx",
                    12_937_772L,
                    "d24fb083ae3b1041fc24e97971d60e280c9342201fbb67b0ab428a8b4a51a434",
                ),
                ModelFileSpec(
                    "tiny-decoder.int8.onnx",
                    "$HF/sherpa-onnx-whisper-tiny/resolve/main/tiny-decoder.int8.onnx",
                    89_855_401L,
                    "d2fece8dd42771f1df975c6c0445770d0c292bf7547c2cae04a6c0cc57540925",
                ),
                ModelFileSpec(
                    "tiny-tokens.txt",
                    "$HF/sherpa-onnx-whisper-tiny/resolve/main/tiny-tokens.txt",
                    816_730L,
                    // Same file as base-tokens.txt (git blob a4edf0b7...); digest
                    // computed locally, cross-checked against the HF git OID.
                    "b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126",
                ),
            ),
            tasks = whisperTasks,
            languages = WHISPER_LANGUAGES,
            minTotalRamMb = 2500,
        ),
        ModelSpec(
            id = "sherpa-onnx-whisper-small",
            label = "Whisper Small (int8)",
            tier = "quality",
            bundled = false,
            dirName = "whisper-small",
            assetDir = null,
            files = listOf(
                ModelFileSpec(
                    "small-encoder.int8.onnx",
                    "$HF/sherpa-onnx-whisper-small/resolve/main/small-encoder.int8.onnx",
                    112_442_483L,
                    "4cbe7b22fa9026b843b60a68640c747de05bafb1a11b57edc0e66c232d9f33a9",
                ),
                ModelFileSpec(
                    "small-decoder.int8.onnx",
                    "$HF/sherpa-onnx-whisper-small/resolve/main/small-decoder.int8.onnx",
                    262_226_114L,
                    "acad50b5c782696e91b55914cc5ab4f756f1532f76e22aa6fc615f39fb69a8ee",
                ),
                ModelFileSpec(
                    "small-tokens.txt",
                    "$HF/sherpa-onnx-whisper-small/resolve/main/small-tokens.txt",
                    816_730L,
                    // Same file as base-tokens.txt (git blob a4edf0b7...).
                    "b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126",
                ),
            ),
            tasks = whisperTasks,
            languages = WHISPER_LANGUAGES,
            minTotalRamMb = 6000,
        ),
    )

    fun byId(id: String): ModelSpec? = all.firstOrNull { it.id == id }
}
