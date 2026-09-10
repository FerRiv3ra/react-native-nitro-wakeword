package com.margelo.nitro.wakeword

import android.content.Context
import java.io.File

/**
 * Resolves a model reference to bytes.
 * Order: absolute path / file:// URI -> app assets (the library's `models/`
 * directory is merged into them, so bundled models resolve here too).
 */
object ModelResolver {
  fun load(context: Context, reference: String): ByteArray {
    val path = when {
      reference.startsWith("file://") -> reference.removePrefix("file://")
      reference.startsWith("/") -> reference
      else -> null
    }
    if (path != null) {
      val file = File(path)
      if (!file.exists()) throw WakeWordException("Model not found: $reference")
      return file.readBytes()
    }
    val assetName = if (reference.contains('.')) reference else "$reference.onnx"
    return try {
      context.assets.open(assetName).use { it.readBytes() }
    } catch (e: Exception) {
      throw WakeWordException("Model not found in assets: $assetName", e)
    }
  }

  fun defaultKeyword(reference: String): String =
    reference.substringAfterLast('/').substringBeforeLast('.')
}
