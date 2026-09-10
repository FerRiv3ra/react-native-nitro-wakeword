package com.margelo.nitro.wakeword

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import ai.onnxruntime.TensorInfo
import java.nio.FloatBuffer
import java.nio.LongBuffer

/** Thin wrapper over an [OrtSession] for float32 models. */
class OnnxModel(private val env: OrtEnvironment, bytes: ByteArray, useXnnpack: Boolean = true) : AutoCloseable {
  val session: OrtSession
  val inputNames: List<String>
  val outputNames: List<String>

  init {
    val options = OrtSession.SessionOptions().apply {
      setIntraOpNumThreads(1)
      setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
      if (useXnnpack) {
        try {
          addXnnpack(mapOf("intra_op_num_threads" to "1"))
        } catch (_: Throwable) {
          // Older runtimes without the XNNPACK EP fall back to the default CPU EP.
        }
      }
    }
    session = env.createSession(bytes, options)
    inputNames = session.inputNames.toList()
    outputNames = session.outputNames.toList()
  }

  /** Declared shape of the first input, `-1` for symbolic dimensions. */
  fun firstInputShape(): LongArray? {
    val info = session.inputInfo.values.firstOrNull()?.info as? TensorInfo ?: return null
    return info.shape
  }

  fun floatTensor(values: FloatArray, shape: LongArray): OnnxTensor =
    OnnxTensor.createTensor(env, FloatBuffer.wrap(values), shape)

  fun int64Scalar(value: Long): OnnxTensor =
    OnnxTensor.createTensor(env, LongBuffer.wrap(longArrayOf(value)), longArrayOf())

  /** Single float input -> first output as flat floats. */
  fun run(input: FloatArray, shape: LongArray): FloatArray {
    val inputName = inputNames.firstOrNull() ?: throw WakeWordException("ONNX model has no input")
    floatTensor(input, shape).use { tensor ->
      session.run(mapOf(inputName to tensor)).use { result ->
        val out = result[0] as OnnxTensor
        return toFloatArray(out)
      }
    }
  }

  fun run(inputs: Map<String, OnnxTensor>): Map<String, FloatArray> {
    session.run(inputs).use { result ->
      val map = HashMap<String, FloatArray>()
      for ((name, value) in result) {
        map[name] = toFloatArray(value as OnnxTensor)
      }
      return map
    }
  }

  private fun toFloatArray(tensor: OnnxTensor): FloatArray {
    val buffer = tensor.floatBuffer
    val out = FloatArray(buffer.remaining())
    buffer.get(out)
    return out
  }

  override fun close() {
    session.close()
  }
}
