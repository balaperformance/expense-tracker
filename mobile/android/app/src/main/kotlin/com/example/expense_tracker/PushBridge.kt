package com.example.expense_tracker

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.TimeZone

/**
 * Push notifications on the Dart side's terms — one method channel:
 *
 *   status              {available, permission}: whether this build has a
 *                       Firebase project, and whether Android may show
 *                       notifications ('granted', 'denied', 'notDetermined')
 *   requestPermission   asks once (Android 13+); earlier versions never ask
 *   getToken            this install's FCM registration token
 *   deleteToken         forgets it — the server's sends to it then fail
 *   setUser(userId)     whose notifications may be shown here (PushStore)
 *   timeZone            the phone's IANA zone: "10 PM" is decided from it
 *   deviceInfo          {device, appVersion}, shown in no notification
 *   takeLaunchPath      the page a tapped notification asked for, once
 *   openSettings        the app's notification settings, to unblock them
 *
 * And one call back into Dart: openPath(path), when a notification is tapped
 * while the app is already running.
 */
class PushBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, CHANNEL)
    private var permissionResult: MethodChannel.Result? = null
    private var launchPath: String? = null

    init {
        channel.setMethodCallHandler { call, result -> handle(call, result) }
    }

    private val prefs get() = activity.getSharedPreferences("expense_tracker_push", Activity.MODE_PRIVATE)

    private fun available(): Boolean = try {
        FirebaseApp.getApps(activity).isNotEmpty()
    } catch (error: Exception) {
        false
    }

    private fun permission(): String {
        if (PushNotifications.canNotify(activity)) return "granted"
        if (Build.VERSION.SDK_INT >= 33 &&
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
            !prefs.getBoolean(ASKED, false)
        ) return "notDetermined"
        return "denied"
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> result.success(mapOf("available" to available(), "permission" to permission()))
            "requestPermission" -> requestPermission(result)
            "getToken" -> {
                if (!available()) {
                    result.error("unavailable", "This build has no Firebase project.", null)
                    return
                }
                FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                    if (task.isSuccessful && !task.result.isNullOrEmpty()) result.success(task.result)
                    else result.error("failed", task.exception?.message ?: "No push token was issued.", null)
                }
            }
            "deleteToken" -> {
                if (!available()) {
                    result.success(null)
                    return
                }
                FirebaseMessaging.getInstance().deleteToken().addOnCompleteListener { task ->
                    if (task.isSuccessful) result.success(null)
                    else result.error("failed", task.exception?.message ?: "The push token could not be removed.", null)
                }
            }
            "setUser" -> {
                PushStore.setUser(activity, call.argument<String>("userId"))
                result.success(null)
            }
            "timeZone" -> result.success(TimeZone.getDefault().id)
            "deviceInfo" -> result.success(
                mapOf(
                    "device" to "${Build.MANUFACTURER} ${Build.MODEL}".trim().take(120),
                    "appVersion" to appVersion(),
                ),
            )
            "takeLaunchPath" -> {
                result.success(launchPath)
                launchPath = null
            }
            "openSettings" -> {
                openSettings()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun appVersion(): String? = try {
        @Suppress("DEPRECATION")
        activity.packageManager.getPackageInfo(activity.packageName, 0).versionName
    } catch (error: Exception) {
        null
    }

    private fun requestPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33 || PushNotifications.canNotify(activity)) {
            // Before Android 13 there is nothing to ask: notifications are on
            // unless the user turned them off in settings.
            result.success(permission())
            return
        }
        if (permissionResult != null) {
            result.error("busy", "Already asking.", null)
            return
        }
        permissionResult = result
        prefs.edit().putBoolean(ASKED, true).apply()
        activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST)
    }

    /** From MainActivity.onRequestPermissionsResult. */
    fun onPermissionResult(requestCode: Int): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        permissionResult?.success(permission())
        permissionResult = null
        return true
    }

    private fun openSettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${activity.packageName}"))
        }
        try {
            activity.startActivity(intent)
        } catch (error: Exception) {
            // No settings screen to open on this device; the app says what to do instead.
        }
    }

    /** The page a tapped notification names, from the intent that opened or resumed the app. */
    fun handleIntent(intent: Intent?, running: Boolean) {
        if (intent?.action != PushNotifications.ACTION_OPEN) return
        val path = PushNotifications.safePath(intent.getStringExtra(PushNotifications.EXTRA_PATH))
        // Consumed once: a later configuration change re-delivers the same intent.
        intent.action = null
        if (running) channel.invokeMethod("openPath", path) else launchPath = path
    }

    companion object {
        const val CHANNEL = "expense_tracker/push"
        private const val PERMISSION_REQUEST = 4712
        private const val ASKED = "permission_asked"
    }
}
