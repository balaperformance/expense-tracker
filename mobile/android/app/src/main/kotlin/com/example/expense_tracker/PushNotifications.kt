package com.example.expense_tracker

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build

/**
 * Draws a notification the push-notify Edge Function sent: the daily
 * reminder, the spending summary, a low balance or a card bill due. Tapping
 * it opens the app on the page it names (MainActivity → Dart).
 *
 * Framework APIs only (no AndroidX), so nothing is added to the build for it.
 */
object PushNotifications {
    const val CHANNEL_ID = "reminders"
    const val ACTION_OPEN = "com.example.expense_tracker.OPEN_NOTIFICATION"
    const val EXTRA_PATH = "path"
    private const val NOTIFICATION_ID = 1

    /** One channel for all four kinds; the user can mute it in Android settings. */
    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(CHANNEL_ID, "Reminders and alerts", NotificationManager.IMPORTANCE_DEFAULT)
        channel.description = "Daily spending reminder, spending summaries, low balances and card bills due"
        manager.createNotificationChannel(channel)
    }

    /** Whether a notification would be shown at all: the user can block them, and Android 13+ asks first. */
    fun canNotify(context: Context): Boolean {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && !manager.areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return false
        return true
    }

    /** Only a path inside the app; anything else a message might name opens the home screen. */
    fun safePath(path: String?): String {
        if (path == null || !path.startsWith("/") || path.startsWith("//") || path.length > 200) return "/"
        return path
    }

    fun show(context: Context, title: String, body: String, path: String?, tag: String?) {
        if (!canNotify(context)) return
        ensureChannel(context)
        val open = Intent(context, MainActivity::class.java).apply {
            action = ACTION_OPEN
            putExtra(EXTRA_PATH, safePath(path))
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val immutable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        val pending = PendingIntent.getActivity(
            context,
            (tag ?: "push").hashCode(),
            open,
            PendingIntent.FLAG_UPDATE_CURRENT or immutable,
        )
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            Notification.Builder(context).setPriority(Notification.PRIORITY_DEFAULT)
        }
        val notification = builder
            .setSmallIcon(R.drawable.ic_stat_notify)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(pending)
            .build()
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        // The same tag replaces an earlier notification instead of stacking another.
        manager.notify(tag ?: "push", NOTIFICATION_ID, notification)
    }
}
