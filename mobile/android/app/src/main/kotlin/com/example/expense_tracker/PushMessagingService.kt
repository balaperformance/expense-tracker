package com.example.expense_tracker

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Receives the push-notify Edge Function's messages, whether the app is open,
 * in the background or closed — Firebase starts this service for each one.
 *
 * Messages are data only, so the app always decides what is shown: a message
 * for an account that is not the one signed in here is dropped (PushStore).
 */
class PushMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        val title = data["title"]?.takeIf { it.isNotBlank() } ?: return
        val body = data["body"] ?: ""
        val audience = data["audience"] ?: return
        if (audience != PushStore.audience(this)) return
        PushNotifications.show(this, title.take(300), body.take(500), data["path"], data["tag"]?.take(80))
    }

    override fun onNewToken(token: String) {
        // Nothing to do here: the token is registered with the signed-in
        // session when the app next opens (it reads the current token then).
    }
}
