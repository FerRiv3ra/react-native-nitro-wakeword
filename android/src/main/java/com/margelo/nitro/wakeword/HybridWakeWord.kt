package com.margelo.nitro.wakeword

import android.Manifest
import android.content.pm.PackageManager
import android.util.Log
import androidx.annotation.Keep
import androidx.core.content.ContextCompat
import com.facebook.proguard.annotations.DoNotStrip
import com.facebook.react.modules.core.PermissionAwareActivity
import com.facebook.react.modules.core.PermissionListener
import com.margelo.nitro.NitroModules
import com.margelo.nitro.core.Promise

@DoNotStrip
@Keep
class HybridWakeWord : HybridWakeWordSpec() {
  companion object {
    private const val PERMISSION_REQUEST_CODE = 0x5742
    private const val LOG_TAG = "NitroWakeWord"
  }

  private val context
    get() = NitroModules.applicationContext ?: throw WakeWordException("React context unavailable")

  @Volatile private var engine: OpenWakeWordEngine? = null
  private var capture: AudioCapture? = null
  private var foregroundService = false
  private var notificationTitle = "Listening"
  private var notificationText = "Wake word detection is active"
  private val lock = Any()

  @Volatile private var detectionListener: ((WakeWordDetection) -> Unit)? = null
  @Volatile private var scoreListener: ((String, Double) -> Unit)? = null
  @Volatile private var errorListener: ((String) -> Unit)? = null

  // Properties

  override val isLoaded: Boolean
    get() = engine != null

  override val isListening: Boolean
    get() = capture?.isRunning == true

  // Lifecycle

  override fun load(config: WakeWordConfig): Promise<Unit> = Promise.async {
    stop()
    if (config.models.isEmpty()) throw WakeWordException("config.models must contain at least one model")
    val ctx = context
    val vadThreshold = (config.vadThreshold ?: 0.3).toFloat()
    val specs = config.models.map { model ->
      OpenWakeWordEngine.KeywordSpec(
        keyword = model.keyword ?: ModelResolver.defaultKeyword(model.model),
        bytes = ModelResolver.load(ctx, model.model),
        threshold = (model.threshold ?: 0.5).toFloat(),
        patience = (model.patience ?: 1.0).toInt(),
      )
    }
    val built = OpenWakeWordEngine(
      melBytes = ModelResolver.load(ctx, "melspectrogram.onnx"),
      embeddingBytes = ModelResolver.load(ctx, "embedding_model.onnx"),
      vadBytes = if (vadThreshold > 0f) ModelResolver.load(ctx, "silero_vad.onnx") else null,
      vadThreshold = vadThreshold,
      refractoryMs = config.refractoryMs ?: 1000.0,
      keywordSpecs = specs,
    )
    synchronized(lock) {
      engine?.close()
      engine = built
      foregroundService = config.foregroundService ?: false
      config.notificationTitle?.let { notificationTitle = it }
      config.notificationText?.let { notificationText = it }
    }
    Log.i(LOG_TAG, "loaded ${specs.size} keyword(s): ${specs.joinToString { "${it.keyword}[w=${built.keywords.first { k -> k.keyword == it.keyword }.window}]" }}, vad=$vadThreshold, foregroundService=$foregroundService")
  }

  override fun unload() {
    stop()
    synchronized(lock) {
      engine?.close()
      engine = null
    }
  }

  override fun start(): Promise<Unit> = Promise.async {
    if (engine == null) throw WakeWordException("Call load() before start()")
    if (!hasMicrophonePermission()) throw WakeWordException("Microphone permission not granted")
    synchronized(lock) {
      if (capture?.isRunning == true) return@async
      val newCapture = AudioCapture(
        chunkSize = OpenWakeWordEngine.CHUNK_SIZE,
        onChunk = { chunk -> processChunk(chunk) },
        onError = { message -> errorListener?.invoke(message) },
      )
      if (foregroundService) {
        Log.i(LOG_TAG, "starting foreground service")
        WakeWordForegroundService.start(context, notificationTitle, notificationText)
      }
      newCapture.start()
      Log.i(LOG_TAG, "listening")
      capture = newCapture
    }
  }

  override fun stop() {
    synchronized(lock) {
      capture?.stop()
      capture = null
      if (foregroundService) {
        try {
          WakeWordForegroundService.stop(context)
        } catch (_: Exception) {
        }
      }
    }
  }

  override fun setThreshold(keyword: String, threshold: Double) {
    engine?.setThreshold(keyword, threshold.toFloat())
  }

  // Listeners

  override fun setDetectionListener(listener: (detection: WakeWordDetection) -> Unit) {
    detectionListener = listener
  }

  override fun clearDetectionListener() {
    detectionListener = null
  }

  override fun setScoreListener(listener: (keyword: String, score: Double) -> Unit) {
    scoreListener = listener
  }

  override fun clearScoreListener() {
    scoreListener = null
  }

  override fun setErrorListener(listener: (message: String) -> Unit) {
    errorListener = listener
  }

  override fun clearErrorListener() {
    errorListener = null
  }

  // Permissions

  override fun hasMicrophonePermission(): Boolean =
    ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

  override fun requestMicrophonePermission(): Promise<Boolean> {
    val promise = Promise<Boolean>()
    if (hasMicrophonePermission()) {
      promise.resolve(true)
      return promise
    }
    val activity = context.currentActivity as? PermissionAwareActivity
    if (activity == null) {
      promise.reject(WakeWordException("No current activity to request permission from"))
      return promise
    }
    val listener = PermissionListener { requestCode, _, grantResults ->
      if (requestCode != PERMISSION_REQUEST_CODE) return@PermissionListener false
      promise.resolve(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
      true
    }
    activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), PERMISSION_REQUEST_CODE, listener)
    return promise
  }

  // Processing (capture thread)

  private fun processChunk(chunk: FloatArray) {
    val engine = engine ?: return
    val result = engine.process(chunk)
    scoreListener?.let { listener ->
      for ((keyword, score) in result.scores) listener(keyword, score.toDouble())
    }
    detectionListener?.let { listener ->
      for (detection in result.detections) {
        listener(WakeWordDetection(detection.keyword, detection.score.toDouble(), detection.timestamp))
      }
    }
  }
}
