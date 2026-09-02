package dev.livelens.livelens

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Bundle

/**
 * Transparent consent flow (contract §5): launches the system
 * media-projection dialog and forwards the result to [CaptureService].
 * Finishes immediately after either outcome; denial is reported via the
 * `projectionDenied` event rather than a result code.
 */
class ProjectionActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (EventsBus.engine?.isRunning == true) {
            finish()
            return
        }
        val mgr = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        @Suppress("DEPRECATION")
        startActivityForResult(mgr.createScreenCaptureIntent(), REQUEST_CONSENT)
    }

    @Deprecated("Deprecated in Java")
    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_CONSENT) {
            finish()
            return
        }
        if (resultCode == RESULT_OK && data != null) {
            val sessionId = intent.getStringExtra(EXTRA_SESSION_ID) ?: ""
            val srcLang = intent.getStringExtra(EXTRA_SRC_LANG)
            val task = intent.getStringExtra(EXTRA_TASK) ?: "translate"
            try {
                startForegroundService(
                    CaptureService.startIntent(this, resultCode, data, sessionId, srcLang, task),
                )
                EventsBus.events.projectionGranted()
            } catch (t: Throwable) {
                // ForegroundServiceStartNotAllowedException & co. must not
                // crash the process — surface as a contract error event.
                EventsBus.events.error(
                    "CAPTURE_INIT_FAILED",
                    "foreground service start failed: ${t.message}",
                )
            }
        } else {
            EventsBus.events.projectionDenied()
        }
        finish()
    }

    companion object {
        const val REQUEST_CONSENT = 9001
        const val EXTRA_SESSION_ID = "sessionId"
        const val EXTRA_SRC_LANG = "srcLang"
        const val EXTRA_TASK = "task"
    }
}
