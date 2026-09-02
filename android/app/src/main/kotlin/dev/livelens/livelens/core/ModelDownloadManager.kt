package dev.livelens.livelens.core

import android.content.Context
import android.os.StatFs
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * On-demand model download manager (PRD E-02).
 *
 * Guarantees, per the requirement row:
 *  - **Resume**: partial files stay in the staging dir; a retry issues a
 *    HTTP `Range` request from the on-disk offset (server 200 → restart).
 *  - **SHA-256**: every completed file is hashed and compared against the
 *    upstream digest in [ModelCatalog] (bundled models skip: empty digest).
 *  - **Atomic swap**: files land in `filesDir/models/.staging/<dir>/` and
 *    are renamed into `filesDir/models/<dir>/` only after verification —
 *    a model dir on disk always means "usable".
 *  - **Space guard**: refuse to start when free space < download size +
 *    margin (surfaces as the `MODEL_SPACE` error code, §4 additive).
 *
 * One download at a time; progress is pushed to Dart via the additive
 * `livelens/model_events` channel (the §3 event set stays frozen).
 */
object ModelDownloadManager {

    enum class Status(val wireName: String) {
        IDLE("idle"),
        DOWNLOADING("downloading"),
        PAUSED("paused"),
        VERIFYING("verifying"),
        DONE("done"),
        FAILED("failed"),
    }

    data class Progress(
        val modelId: String,
        val status: Status,
        val bytesDone: Long,
        val bytesTotal: Long,
        val error: String? = null,
    ) {
        fun toWire(): Map<String, Any?> = mapOf(
            "type" to "modelDownload",
            "v" to 1,
            "modelId" to modelId,
            "state" to status.wireName,
            "bytesDone" to bytesDone,
            "bytesTotal" to bytesTotal,
            "error" to (error ?: ""),
        )
    }

    /** Single sink wired to the `livelens/model_events` EventChannel. */
    @Volatile var listener: ((Progress) -> Unit)? = null

    private val states = ConcurrentHashMap<String, Progress>()
    private val pauseFlags = ConcurrentHashMap<String, AtomicBoolean>()
    private val cancelFlags = ConcurrentHashMap<String, AtomicBoolean>()
    private val active = AtomicBoolean(false)

    /** Extra headroom demanded by the space guard (extraction + ONNX workspace). */
    private const val SPACE_MARGIN_BYTES = 250L * 1024 * 1024

    private const val CONNECT_TIMEOUT_MS = 15_000
    private const val READ_TIMEOUT_MS = 30_000
    private const val MAX_RETRIES = 5
    private const val PROGRESS_CHUNK = 256L * 1024

    fun stateOf(modelId: String): Status =
        states[modelId]?.status ?: Status.IDLE

    fun progressOf(modelId: String): Progress? = states[modelId]

    fun stagingDir(context: Context, spec: ModelSpec): File =
        File(File(context.filesDir, "models"), ".staging/${spec.dirName}")

    /**
     * Starts (or resumes) the download for [modelId]. Returns false when the
     * model is unknown/bundled or another download is already running.
     */
    fun start(context: Context, modelId: String): Boolean {
        val spec = ModelCatalog.byId(modelId) ?: return false
        if (spec.bundled) return false
        if (!active.compareAndSet(false, true)) return false
        val appContext = context.applicationContext
        Thread {
            try {
                runDownload(appContext, spec)
            } finally {
                active.set(false)
            }
        }.start()
        return true
    }

    /** Cooperative pause; the worker stops at the next buffer boundary. */
    fun pause(modelId: String) {
        pauseFlags[modelId]?.set(true)
        cancelFlags[modelId]?.set(false)
    }

    /** Cooperative cancel; clears the staging dir and resets to IDLE. */
    fun cancel(context: Context, modelId: String) {
        val spec = ModelCatalog.byId(modelId) ?: return
        cancelFlags[modelId]?.set(true)
        pauseFlags[modelId]?.set(false)
        if (!active.get()) {
            stagingDir(context, spec).deleteRecursively()
            emit(Progress(modelId, Status.IDLE, 0, spec.totalBytes))
        }
    }

    fun resume(context: Context, modelId: String): Boolean = start(context, modelId)

    // ------------------------------------------------------------------ //

    private fun emit(p: Progress) {
        states[p.modelId] = p
        listener?.invoke(p)
    }

    private fun runDownload(context: Context, spec: ModelSpec) {
        val total = spec.totalBytes
        val stat = StatFs(context.filesDir.path)
        if (stat.availableBytes < total + SPACE_MARGIN_BYTES) {
            emit(Progress(spec.id, Status.FAILED, 0, total, "MODEL_SPACE"))
            return
        }

        val staging = stagingDir(context, spec)
        staging.mkdirs()
        pauseFlags[spec.id] = AtomicBoolean(false)
        cancelFlags[spec.id] = AtomicBoolean(false)

        for (file in spec.files) {
            // false = paused/cancelled/failed — state already emitted.
            if (!downloadFile(spec, file, staging)) return
        }

        emit(Progress(spec.id, Status.VERIFYING, total, total))
        for (file in spec.files) {
            if (file.sha256.isEmpty()) continue
            val actual = File(staging, file.name).sha256Hex()
            if (actual == null || !actual.equals(file.sha256, ignoreCase = true)) {
                staging.deleteRecursively()
                emit(Progress(spec.id, Status.FAILED, total, total, "MODEL_CHECKSUM"))
                return
            }
        }

        // Atomic install: a model dir on disk ⇔ fully verified file set.
        val dest = File(File(context.filesDir, "models"), spec.dirName)
        dest.deleteRecursively()
        if (!staging.renameTo(dest)) {
            // Renames inside filesDir don't fail in practice, but stay honest
            // if a filesystem ever refuses: fall back to copy + delete.
            if (!staging.copyRecursively(dest, overwrite = true)) {
                dest.deleteRecursively()
                emit(Progress(spec.id, Status.FAILED, total, total, "MODEL_DOWNLOAD_FAILED"))
                return
            }
            staging.deleteRecursively()
        }
        emit(Progress(spec.id, Status.DONE, total, total))
    }

    /**
     * Downloads one file into [staging] with resume. Returns true only when
     * the file completed; false means paused, cancelled, or failed (state
     * already emitted).
     */
    private fun downloadFile(spec: ModelSpec, file: ModelFileSpec, staging: File): Boolean {
        val out = File(staging, file.name)
        val cancel = cancelFlags[spec.id]!!
        val paused = pauseFlags[spec.id]!!

        var attempt = 0
        var done = if (out.isFile) out.length() else 0L
        while (attempt < MAX_RETRIES) {
            attempt++
            if (cancel.get()) {
                staging.deleteRecursively()
                emit(Progress(spec.id, Status.IDLE, 0, spec.totalBytes))
                return false
            }
            if (paused.get()) {
                emit(Progress(spec.id, Status.PAUSED, done, spec.totalBytes))
                return false
            }
            try {
                val conn = URL(file.url).openConnection() as HttpURLConnection
                conn.connectTimeout = CONNECT_TIMEOUT_MS
                conn.readTimeout = READ_TIMEOUT_MS
                conn.instanceFollowRedirects = true
                if (done > 0) conn.setRequestProperty("Range", "bytes=$done-")
                conn.connect()

                var offset = done
                when (conn.responseCode) {
                    206 -> Unit // resuming from [done]
                    200 -> { // server ignored Range (or fresh start)
                        offset = 0
                        out.delete()
                    }
                    else -> {
                        conn.disconnect()
                        emit(Progress(spec.id, Status.FAILED, done, spec.totalBytes, "MODEL_DOWNLOAD_FAILED"))
                        return false
                    }
                }

                conn.inputStream.use { input ->
                    java.io.FileOutputStream(out, offset > 0).use { output ->
                        val buf = ByteArray(64 * 1024)
                        var sinceEmit = 0L
                        while (true) {
                            if (cancel.get()) {
                                staging.deleteRecursively()
                                emit(Progress(spec.id, Status.IDLE, 0, spec.totalBytes))
                                return false
                            }
                            if (paused.get()) {
                                emit(Progress(spec.id, Status.PAUSED, offset, spec.totalBytes))
                                return false
                            }
                            val n = input.read(buf)
                            if (n < 0) break
                            output.write(buf, 0, n)
                            offset += n
                            sinceEmit += n
                            if (sinceEmit >= PROGRESS_CHUNK) {
                                sinceEmit = 0
                                emit(Progress(spec.id, Status.DOWNLOADING, offset, spec.totalBytes))
                            }
                        }
                        output.flush()
                    }
                }
                conn.disconnect()
                done = offset
                if (done != file.sizeBytes) continue // truncated stream — retry from offset
                emit(Progress(spec.id, Status.DOWNLOADING, done, spec.totalBytes))
                return true
            } catch (t: Throwable) {
                // Network hiccup: retry from the on-disk offset after a beat.
                done = if (out.isFile) out.length() else 0L
                try {
                    Thread.sleep(1_000L * attempt)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
            }
        }
        emit(Progress(spec.id, Status.FAILED, done, spec.totalBytes, "MODEL_DOWNLOAD_FAILED"))
        return false
    }

    private fun File.sha256Hex(): String? = try {
        val md = MessageDigest.getInstance("SHA-256")
        inputStream().use { input ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
        }
        md.digest().joinToString("") { "%02x".format(it) }
    } catch (_: Throwable) {
        null
    }
}
