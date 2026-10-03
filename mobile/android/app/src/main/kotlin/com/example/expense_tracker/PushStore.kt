package com.example.expense_tracker

import android.content.Context
import java.security.MessageDigest

/**
 * Whose notifications this phone shows.
 *
 * Every push carries an `audience`: the first 32 hex digits of SHA-256 of the
 * user id it was sent to (push-notify core/fcm.ts `audienceOf`). The app
 * stores the same digest for the user signed in here when notifications are
 * turned on, and clears it on sign-out — so a phone that signed out, or that
 * someone else signed in to, never shows another account's figures, even if
 * its token could not be unregistered (offline at sign-out).
 */
object PushStore {
    private const val PREFS = "expense_tracker_push"
    private const val AUDIENCE = "audience"

    fun setUser(context: Context, userId: String?) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
        if (userId.isNullOrEmpty()) prefs.remove(AUDIENCE) else prefs.putString(AUDIENCE, audienceOf(userId))
        prefs.apply()
    }

    fun audience(context: Context): String? =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(AUDIENCE, null)

    fun audienceOf(userId: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(userId.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }.substring(0, 32)
    }
}
