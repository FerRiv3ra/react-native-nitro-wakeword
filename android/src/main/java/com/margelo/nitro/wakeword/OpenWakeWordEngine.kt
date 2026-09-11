package com.margelo.nitro.wakeword

import ai.onnxruntime.OrtEnvironment

/**
 * openWakeWord inference pipeline (see NOTICE).
 *
 * 16 kHz mono int16-scaled float audio, processed in 80 ms chunks (1280 samples).
 * Each chunk: melspectrogram over the last 1760 samples -> 8 new mel frames (32 bins),
 * transformed `x / 10 + 2`; the last 76 mel frames -> one 96-dim speech embedding;
 * the last `N` embeddings (`N` = classifier window, usually 16) -> keyword score.
 * Optionally gated by Silero VAD.
 */
class OpenWakeWordEngine(
  melBytes: ByteArray,
  embeddingBytes: ByteArray,
  vadBytes: ByteArray?,
  private val vadThreshold: Float,
  refractoryMs: Double,
  keywordSpecs: List<KeywordSpec>,
) : AutoCloseable {
  companion object {
    const val SAMPLE_RATE = 16000
    const val CHUNK_SIZE = 1280
    const val MEL_CONTEXT = 480
    const val MEL_WINDOW = 76
    const val MEL_BINS = 32
    const val EMBEDDING_DIM = 96
    const val VAD_FRAME = 512
    const val VAD_HISTORY = 12
  }

  data class KeywordSpec(val keyword: String, val bytes: ByteArray, val threshold: Float, val patience: Int)
  data class Detection(val keyword: String, val score: Float, val timestamp: Double)
  data class Result(val scores: List<Pair<String, Float>>, val detections: List<Detection>)

  class Keyword(
    val keyword: String,
    val model: OnnxModel,
    val window: Int,
    @Volatile var threshold: Float,
    val patience: Int,
  ) {
    var consecutive = 0
    var lastDetection = 0.0
  }

  private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
  private val melModel = OnnxModel(env, melBytes)
  private val embeddingModel = OnnxModel(env, embeddingBytes)
  private val vadModel: OnnxModel? = if (vadThreshold > 0f && vadBytes != null) OnnxModel(env, vadBytes) else null
  private val refractorySeconds = refractoryMs / 1000.0
  val keywords: List<Keyword>
  private val maxWindow: Int

  private val raw = FloatArray(CHUNK_SIZE + MEL_CONTEXT)
  private val mel = FloatArray(MEL_WINDOW * MEL_BINS) { 1f }
  private var melFramesSeen = 0
  private val features: FloatArray
  private var featuresSeen = 0

  private var vadH = FloatArray(2 * 64)
  private var vadC = FloatArray(2 * 64)
  private val vadPending = FloatArray(CHUNK_SIZE * 2)
  private var vadPendingCount = 0
  private val vadScores = FloatArray(VAD_HISTORY)
  private var vadIndex = 0

  init {
    keywords = keywordSpecs.map { spec ->
      val model = OnnxModel(env, spec.bytes)
      Keyword(spec.keyword, model, resolveWindow(model, spec.keyword), spec.threshold, maxOf(1, spec.patience))
    }
    maxWindow = keywords.maxOfOrNull { it.window } ?: 16
    features = FloatArray(maxWindow * EMBEDDING_DIM)
    warmUp()
  }

  private fun resolveWindow(model: OnnxModel, name: String): Int {
    val shape = model.firstInputShape()
    if (shape != null && shape.size == 3 && shape[1] > 0) return shape[1].toInt()
    // Symbolic dimension: probe common sizes.
    for (n in intArrayOf(16, 28, 20, 24, 32, 12, 36, 40, 48, 64, 8)) {
      try {
        model.run(FloatArray(n * EMBEDDING_DIM), longArrayOf(1, n.toLong(), EMBEDDING_DIM.toLong()))
        return n
      } catch (_: Exception) {
      }
    }
    throw WakeWordException("Could not determine input window of classifier '$name'. Expected [1, N, 96].")
  }

  private fun warmUp() {
    val zeros = FloatArray(CHUNK_SIZE)
    repeat(MEL_WINDOW / 8 + maxWindow + 2) { processChunk(zeros, emit = false) }
    keywords.forEach { it.consecutive = 0; it.lastDetection = 0.0 }
    vadScores.fill(0f)
  }

  /**
   * Flushes every buffer back to "silence". Call before (re)starting capture:
   * the mel/embedding windows still hold the audio that triggered the last
   * detection, and would fire again on the first chunk after a stop/start.
   */
  fun reset() {
    raw.fill(0f)
    mel.fill(1f)
    melFramesSeen = 0
    features.fill(0f)
    featuresSeen = 0
    vadH = FloatArray(2 * 64)
    vadC = FloatArray(2 * 64)
    vadPendingCount = 0
    vadIndex = 0
    warmUp()
  }

  fun setThreshold(keyword: String, threshold: Float) {
    keywords.firstOrNull { it.keyword == keyword }?.threshold = threshold
  }

  /** Processes exactly one 1280-sample chunk. Must be called from a single thread. */
  fun process(chunk: FloatArray): Result = processChunk(chunk, emit = true)

  private fun processChunk(chunk: FloatArray, emit: Boolean): Result {
    require(chunk.size == CHUNK_SIZE) { "chunk must be 1280 samples" }

    if (vadModel != null) runVad(chunk)

    // Sliding raw buffer: [ previous 480 | new 1280 ]
    System.arraycopy(raw, raw.size - MEL_CONTEXT, raw, 0, MEL_CONTEXT)
    System.arraycopy(chunk, 0, raw, MEL_CONTEXT, CHUNK_SIZE)

    val melOut = melModel.run(raw, longArrayOf(1, raw.size.toLong()))
    val newFrames = melOut.size / MEL_BINS
    if (newFrames == 0) return Result(emptyList(), emptyList())
    for (i in melOut.indices) melOut[i] = melOut[i] / 10f + 2f
    appendFrames(melOut, newFrames * MEL_BINS, mel)
    melFramesSeen += newFrames
    if (melFramesSeen < MEL_WINDOW) return Result(emptyList(), emptyList())

    val embedding = embeddingModel.run(mel, longArrayOf(1, MEL_WINDOW.toLong(), MEL_BINS.toLong(), 1))
    appendFrames(embedding, EMBEDDING_DIM, features)
    featuresSeen += 1

    val scores = ArrayList<Pair<String, Float>>(keywords.size)
    val detections = ArrayList<Detection>(0)
    val speech = vadModel == null || vadScores.max() >= vadThreshold
    val now = System.currentTimeMillis() / 1000.0

    for (keyword in keywords) {
      if (featuresSeen < keyword.window) continue
      // VAD gate closed: the score would be forced to 0 anyway, skip the classifier.
      val score = if (!speech) 0f else {
        val length = keyword.window * EMBEDDING_DIM
        val slice = features.copyOfRange(features.size - length, features.size)
        keyword.model.run(slice, longArrayOf(1, keyword.window.toLong(), EMBEDDING_DIM.toLong())).firstOrNull() ?: 0f
      }
      scores.add(keyword.keyword to score)
      if (!emit) continue

      if (score >= keyword.threshold) keyword.consecutive += 1 else keyword.consecutive = 0
      if (keyword.consecutive >= keyword.patience && now - keyword.lastDetection >= refractorySeconds) {
        keyword.lastDetection = now
        keyword.consecutive = 0
        detections.add(Detection(keyword.keyword, score, now * 1000))
      }
    }
    return Result(scores, detections)
  }

  /** Shifts `buffer` left by `count` and appends the first `count` values of `values`. */
  private fun appendFrames(values: FloatArray, requested: Int, buffer: FloatArray) {
    val count = minOf(requested, values.size)
    if (count <= 0) return
    if (count >= buffer.size) {
      System.arraycopy(values, count - buffer.size, buffer, 0, buffer.size)
      return
    }
    System.arraycopy(buffer, count, buffer, 0, buffer.size - count)
    System.arraycopy(values, 0, buffer, buffer.size - count, count)
  }

  private fun runVad(chunk: FloatArray) {
    val vad = vadModel ?: return
    // Silero expects audio normalised to [-1, 1].
    for (i in chunk.indices) vadPending[vadPendingCount + i] = chunk[i] / 32768f
    vadPendingCount += chunk.size
    var latest: Float? = null
    while (vadPendingCount >= VAD_FRAME) {
      val input = vadPending.copyOfRange(0, VAD_FRAME)
      System.arraycopy(vadPending, VAD_FRAME, vadPending, 0, vadPendingCount - VAD_FRAME)
      vadPendingCount -= VAD_FRAME
      val inputTensor = vad.floatTensor(input, longArrayOf(1, VAD_FRAME.toLong()))
      val srTensor = vad.int64Scalar(SAMPLE_RATE.toLong())
      val hTensor = vad.floatTensor(vadH, longArrayOf(2, 1, 64))
      val cTensor = vad.floatTensor(vadC, longArrayOf(2, 1, 64))
      try {
        val outputs = vad.run(mapOf("input" to inputTensor, "sr" to srTensor, "h" to hTensor, "c" to cTensor))
        outputs["hn"]?.let { vadH = it }
        outputs["cn"]?.let { vadC = it }
        outputs["output"]?.firstOrNull()?.let { latest = it }
      } finally {
        inputTensor.close(); srTensor.close(); hTensor.close(); cTensor.close()
      }
    }
    latest?.let {
      vadScores[vadIndex] = it
      vadIndex = (vadIndex + 1) % vadScores.size
    }
  }

  override fun close() {
    keywords.forEach { it.model.close() }
    vadModel?.close()
    embeddingModel.close()
    melModel.close()
  }
}
