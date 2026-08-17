package com.example.omkar

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

class NotificationHelper(
    private val context: Context
) {

    companion object {

        private const val CHANNEL_ID = "scam_alerts"
        private const val CHANNEL_NAME = "Scam Alerts"
        private const val CHANNEL_DESCRIPTION =
            "Notifications for detected scam messages"

    }

    init {
        createNotificationChannel()
    }

    private fun createNotificationChannel() {

        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_HIGH
        ).apply {

            description = CHANNEL_DESCRIPTION
        }

        val manager =
            context.getSystemService(
                Context.NOTIFICATION_SERVICE
            ) as NotificationManager

        manager.createNotificationChannel(channel)
    }

    fun showScamAlert(
        riskLevel: String,
        reason: String
    ) {

        if (
            android.os.Build.VERSION.SDK_INT >=
            android.os.Build.VERSION_CODES.TIRAMISU
        ) {

            if (
                context.checkSelfPermission(
                    Manifest.permission.POST_NOTIFICATIONS
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                return
            }
        }

        val notification =
            NotificationCompat.Builder(
                context,
                CHANNEL_ID
            )
                .setSmallIcon(
                    android.R.drawable.ic_dialog_alert
                )
                .setContentTitle(
                    "⚠️ $riskLevel Risk Scam Detected"
                )
                .setContentText(
                    reason
                )
                .setStyle(
                    NotificationCompat.BigTextStyle()
                        .bigText(
                            "Risk Level: $riskLevel\n\n" +
                                    "Reason: $reason"
                        )
                )
                .setPriority(
                    NotificationCompat.PRIORITY_HIGH
                )
                .setAutoCancel(true)
                .build()

        NotificationManagerCompat
            .from(context)
            .notify(
                1001,
                notification
            )
    }
}
