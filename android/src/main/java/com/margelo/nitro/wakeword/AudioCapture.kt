package com.margelo.nitro.wakeword

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Process

/**
 * Reads 16 kHz mono PCM16 from [AudioRecord] on a dedicated thread and hands
 * fixed 1280-sample chunks (as int16-scaled floats) to [onChunk].
 * `onChunk` runs on the capture thread, which gives natural back-pressure.
 */
class AudioCapture(
  private val chunkSize: Int,
  private val onChunk: (FloatArray) -> Unit,
  private val onError: (String) -> Unit,
) {
  @Volatile var isRunning = false
    private set
  private var thread: Thread? = null
  private var record: AudioRecord? = null

  @SuppressLint("MissingPermission")
  fun start() {
    if (isRunning) return
    val sampleRate = OpenWakeWordEngine.SAMPLE_RATE
    val minBuffer = AudioRecord.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
    if (minBuffer <= 0) throw WakeWordException("AudioRecord.getMinBufferSize failed ($minBuffer)")
    val bufferSize = maxOf(minBuffer, chunkSize * 2 * 10)
    val recorder = AudioRecord(
      MediaRecorder.AudioSource.VOICE_RECOGNITION,
      sampleRate,
      AudioFormat.CHANNEL_IN_MONO,
      AudioFormat.ENCODING_PCM_16BIT,
      bufferSize,
    )
    if (recorder.state != AudioRecord.STATE_INITIALIZED) {
      recorder.release()
      throw WakeWordException("AudioRecord failed to initialize")
    }
    record = recorder
    isRunning = true
    recorder.startRecording()
    thread = Thread({ loop(recorder) }, "NitroWakeWord-audio").apply {
      priority = Thread.MAX_PRIORITY
      start()
    }
  }

  private fun loop(recorder: AudioRecord) {
    Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
    val shorts = ShortArray(chunkSize)
    val floats = FloatArray(chunkSize)
    while (isRunning) {
      var filled = 0
      while (filled < chunkSize && isRunning) {
        val read = recorder.read(shorts, filled, chunkSize - filled, AudioRecord.READ_BLOCKING)
        if (read < 0) {
          onError("AudioRecord.read failed ($read)")
          isRunning = false
          break
        }
        filled += read
      }
      if (!isRunning) break
      for (i in 0 until chunkSize) floats[i] = shorts[i].toFloat()
      try {
        onChunk(floats)
      } catch (e: Exception) {
        onError("Inference failed: ${e.message}")
      }
    }
  }

  fun stop() {
    if (!isRunning) return
    isRunning = false
    thread?.join(1000)
    thread = null
    record?.let {
      try {
        it.stop()
      } catch (_: Exception) {
      }
      it.release()
    }
    record = null
  }
}
