package com.margelo.nitro.wakeword

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Keeps microphone access alive while the app is in the background.
 * Holds no state of its own: the capture thread lives in [HybridWakeWord].
 */
class WakeWordForegroundService : Service() {
  companion object {
    const val CHANNEL_ID = "nitro_wakeword"
    const val NOTIFICATION_ID = 0x5741
    const val EXTRA_TITLE = "title"
    const val EXTRA_TEXT = "text"

    fun start(context: Context, title: String, text: String) {
      val intent = Intent(context, WakeWordForegroundService::class.java)
        .putExtra(EXTRA_TITLE, title)
        .putExtra(EXTRA_TEXT, text)
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        context.startForegroundService(intent)
      } else {
        context.startService(intent)
      }
    }

    fun stop(context: Context) {
      context.stopService(Intent(context, WakeWordForegroundService::class.java))
    }
  }

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Listening"
    val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Wake word detection is active"
    val notification = buildNotification(title, text)
    Log.i("NitroWakeWord", "foreground service started")
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
      startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
    } else {
      startForeground(NOTIFICATION_ID, notification)
    }
    return START_NOT_STICKY
  }

  private fun buildNotification(title: String, text: String): Notification {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      val manager = getSystemService(NotificationManager::class.java)
      val channel = NotificationChannel(CHANNEL_ID, "Wake word", NotificationManager.IMPORTANCE_LOW)
      manager.createNotificationChannel(channel)
    }
    return NotificationCompat.Builder(this, CHANNEL_ID)
      .setContentTitle(title)
      .setContentText(text)
      .setSmallIcon(applicationInfo.icon)
      .setOngoing(true)
      .setPriority(NotificationCompat.PRIORITY_LOW)
      .setCategory(NotificationCompat.CATEGORY_SERVICE)
      .build()
  }
}
