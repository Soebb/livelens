package dev.livelens.livelens.core

import android.app.ActivityManager
import android.content.Context
import java.io.File
import java.util.concurrent.atomic.AtomicReference

/**
 * Curated model registry (contract §2.2, PRD E-01/E-04).
 *
 * Entries come from [ModelCatalog]; "installed" means the model's verified
 * file set exists under `filesDir/models/<dir>/` (bundled models are
 * materialized from APK assets on first [load]).
 *
 * [load] hot-swaps engines: the previous recognizer is closed only after
 * the replacement is fully constructed, so a running session that reads
 * [transcriber] per decode never sees null (E-04: no service restart).
 * [load] is idempotent per model id and must be called off the main thread
 * (asset copy + ONNX session init take seconds).
 */
object ModelRegistry {

    private val loaded = AtomicReference<SherpaWhisperTranscriber?>()

    @Volatile
    var loadedModelId: String? = null
        private set

    /** The live engine, or [NoopTranscriber] while nothing is loaded. */
    val transcriber: Transcriber
        get() = loaded.get() ?: NoopTranscriber()

    /** Whether any Whisper engine is hot. */
    val isLoaded: Boolean get() = loaded.get() != null

    /** Total device RAM in MB, for the quality-tier pre-check (E-01). */
    fun deviceTotalRamMb(context: Context): Int {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val mem = ActivityManager.MemoryInfo()
        am.getMemoryInfo(mem)
        return (mem.totalMem / (1024L * 1024L)).toInt()
    }

    /** Registry entries for `getCapabilities.availableModels` (§2.2 + additive). */
    fun availableModels(context: Context): List<Map<String, Any>> = ModelCatalog.all.map { spec ->
        mapOf(
            "id" to spec.id,
            "label" to spec.label,
            "tier" to spec.tier,
            "sizeBytes" to spec.totalBytes,
            // Bundled models ship inside the signed APK, so they are always
            // "installed" from the user's perspective; materialization to
            // filesDir happens lazily inside [load].
            "installed" to (isInstalled(context, spec) || spec.bundled),
            // Additive capability-matrix fields (Epic 6 validation banner):
            "downloadable" to !spec.bundled,
            "tasks" to spec.tasks,
            "languages" to spec.languages,
            "minRamMb" to spec.minTotalRamMb,
            "downloadState" to ModelDownloadManager.stateOf(spec.id).wireName,
        )
    }

    fun installDir(context: Context, spec: ModelSpec): File =
        File(File(context.filesDir, "models"), spec.dirName)

    /**
     * Copies bundled APK-asset files into the install dir (first run only).
     * Downloadable specs are untouched — they arrive via the download
     * manager. Blocking IO; only invoked from background threads.
     *
     * Integrity: bundled files come from the signed APK, so the digest is
     * delegated to the APK signature; the per-file size check below catches
     * truncated/partial copies.
     */
    private fun ensureMaterialized(context: Context, spec: ModelSpec) {
        if (!spec.bundled || isInstalled(context, spec)) return
        val assetRoot = spec.assetDir
            ?: throw IllegalStateException("bundled spec without assetDir: ${spec.id}")
        val dir = installDir(context, spec)
        dir.mkdirs()
        for (f in spec.files) {
            val dst = File(dir, f.name)
            if (dst.isFile && dst.length() == f.sizeBytes) continue
            val tmp = File(dir, "${f.name}.part")
            try {
                context.assets.open("$assetRoot/${f.name}").use { input ->
                    tmp.outputStream().use { input.copyTo(it) }
                }
                if (tmp.length() != f.sizeBytes) {
                    throw IllegalStateException(
                        "asset size mismatch for ${f.name}: ${tmp.length()} != ${f.sizeBytes}",
                    )
                }
                if (!tmp.renameTo(dst)) {
                    throw IllegalStateException("asset install failed for ${f.name}")
                }
            } finally {
                if (tmp.exists()) tmp.delete()
            }
        }
    }

    /** True when every file of [spec] exists in its install dir. */
    fun isInstalled(context: Context, spec: ModelSpec): Boolean =
        spec.files.all { File(installDir(context, spec), it.name).isFile }

    /**
     * Hot-loads (or hot-swaps to) [modelId]. Returns the live engine for the
     * requested id. Blocking; invoke from a background dispatcher.
     *
     * @throws IllegalArgumentException when the model id is unknown
     *   (caller maps to `MODEL_MISSING`, §2.2)
     * @throws IllegalStateException when the model is not installed or the
     *   device lacks the RAM headroom for its tier (E-01 quality gate)
     * @throws RuntimeException when ONNX session init fails (`MODEL_LOAD_FAILED`)
     */
    fun load(context: Context, modelId: String): SherpaWhisperTranscriber {
        val spec = ModelCatalog.byId(modelId)
            ?: throw IllegalArgumentException("unknown model: $modelId")

        loaded.get()?.let { if (loadedModelId == modelId) return it }

        synchronized(this) {
            loaded.get()?.let { if (loadedModelId == modelId) return it }

            Breadcrumbs.mark("model.load.begin", "${spec.id} (${spec.tier})")
            val ramMb = deviceTotalRamMb(context)
            if (ramMb < spec.minTotalRamMb) {
                Breadcrumbs.mark(
                    "model.load.fail",
                    "RAM gate: device ${ramMb}MB < required ${spec.minTotalRamMb}MB for ${spec.id}",
                )
                throw IllegalStateException(
                    "device RAM ${ramMb}MB below required ${spec.minTotalRamMb}MB for tier ${spec.tier}",
                )
            }

            // Bundled engine: materialize APK assets to filesDir first.
            ensureMaterialized(context, spec)
            if (!isInstalled(context, spec)) {
                Breadcrumbs.mark("model.load.fail", "model not installed: $modelId")
                throw IllegalStateException("model not installed: $modelId")
            }

            try {
                val replacement = SherpaWhisperTranscriber.create(
                    context,
                    spec,
                    installDir(context, spec),
                )
                val previous = loaded.getAndSet(replacement)
                loadedModelId = modelId
                // Close AFTER the swap so an in-flight decode on the old engine
                // finishes against a valid recognizer (hot-swap safety, E-04).
                previous?.close()
                Breadcrumbs.mark("model.load.ok", spec.id)
                return replacement
            } catch (t: Throwable) {
                // Record the real failure reason — JNI/ONNX init errors were
                // previously invisible (swallowed by callers).
                Breadcrumbs.mark(
                    "model.load.fail",
                    "${t.javaClass.simpleName}: ${t.message} (${spec.id})",
                )
                throw t
            }
        }
    }

    /** Hot-unload (memory pressure / model delete). Re-loadable afterwards. */
    fun unload() {
        synchronized(this) {
            loaded.getAndSet(null)?.close()
            loadedModelId = null
        }
    }
}
