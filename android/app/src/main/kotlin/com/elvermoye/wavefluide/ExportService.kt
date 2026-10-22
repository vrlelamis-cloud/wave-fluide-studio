package com.elvermoye.wavefluide

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Service de premier plan « Export en cours » : évite que le système tue
 * l'application pendant l'encodage vidéo si l'utilisateur passe en arrière-plan.
 */
class ExportService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ActionStart
        if (action == ActionStop) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        val channel = "wave_fluide_export"
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(channel, "Export vidéo", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val notif: Notification = NotificationCompat.Builder(this, channel)
            .setContentTitle("Wave Fluide Studio")
            .setContentText("Export en cours…")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(2, notif, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING)
        } else {
            startForeground(2, notif)
        }
        return START_NOT_STICKY
    }

    companion object {
        const val ActionStart = "com.elvermoye.wavefluide.START"
        const val ActionStop = "com.elvermoye.wavefluide.STOP"
    }
}
