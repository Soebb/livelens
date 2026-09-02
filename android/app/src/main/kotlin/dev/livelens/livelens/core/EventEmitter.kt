package dev.livelens.livelens.core

/**
 * Thread-safe typed event sink over EventChannel `livelens/events`
 * (docs/contract.md §3).
 *
 * - Every payload is a JSON-able map stamped with `"type"` and `"v": 1`.
 * - Emits from any thread; the actual dispatch happens on the platform
 *   main thread (EventSink requirement).
 * - Null sink (no listener yet / channel torn down) → event dropped.
 *   Contract: losing events before the Dart side subscribes is acceptable;
   after subscribe, the EventChannel buffers.
 */
class EventEmitter {
    /** Minimal sink abstraction so unit tests can inject a recorder. */
    interface Sink {
        fun success(event: Any?)
    }

    @Volatile
    private var sink: Sink? = null

    fun attach(sink: Sink?) {
        this.sink = sink
    }

    fun detach() {
        this.sink = null
    }

    /**
     * Emits an event of [type] merging [body] with the envelope
     * `{type, v:1, ...body}`. Safe from any thread.
     */
    fun emit(type: String, body: Map<String, Any?> = emptyMap()) {
        val s = sink ?: return
        val payload = HashMap<String, Any?>(body.size + 2)
        payload["type"] = type
        payload["v"] = 1
        payload.putAll(body)
        s.success(payload)
    }

    fun state(value: String, detail: String = "") = emit("state", mapOf("value" to value, "detail" to detail))

    fun projectionGranted() = emit("projectionGranted")

    fun projectionDenied() = emit("projectionDenied")

    fun partial(sessionId: String, segId: String, showHint: Boolean) =
        emit("partial", mapOf("sessionId" to sessionId, "segId" to segId, "showHint" to showHint))

    fun final(
        sessionId: String,
        segId: String,
        t0: Double,
        t1: Double,
        srcLang: String,
        src: String,
        en: String,
        conf: Double,
    ) = emit(
        "final",
        mapOf(
            "sessionId" to sessionId, "segId" to segId, "t0" to t0, "t1" to t1,
            "srcLang" to srcLang, "src" to src, "en" to en, "conf" to conf,
        ),
    )

    fun perf(rtfMsPerSec: Int, queueDepth: Int, rssMb: Double, batteryDrop: Double) = emit(
        "perf",
        mapOf(
            "rtfMsPerSec" to rtfMsPerSec,
            "queueDepth" to queueDepth,
            "rssMb" to rssMb,
            "batteryPctDropLastPeriod" to batteryDrop,
        ),
    )

    fun spoolPending(count: Int) = emit("spoolPending", mapOf("count" to count))

    fun error(code: String, detail: String) = emit("error", mapOf("code" to code, "detail" to detail))
}
