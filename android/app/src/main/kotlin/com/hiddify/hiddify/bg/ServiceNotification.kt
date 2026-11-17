package com.hiddify.hiddify.bg

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.util.Log
import androidx.annotation.StringRes
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.MutableLiveData
import com.hiddify.core.api.v2.hcommon.Empty
import com.hiddify.core.api.v2.hcore.CoreClient
import com.hiddify.core.api.v2.hcore.SystemInfo
import com.hiddify.hiddify.Application
import com.hiddify.hiddify.MainActivity
import com.hiddify.hiddify.R
import com.hiddify.hiddify.Settings
import com.hiddify.hiddify.constant.Action
import com.hiddify.hiddify.constant.ServiceMode
import com.hiddify.hiddify.constant.Status
import com.hiddify.core.libbox.Libbox
import com.hiddify.hiddify.utils.GrpcClientProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.isActive

import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.CancellationException
/**
 * The persistent notification of the running service.
 *
 * Title: the active profile. Text: the outbound in use, prefixed with the live speed when
 * "Display speed in notification" is on. Header: VPN or Proxy. Everything comes from the core
 * (SystemInfo), so a profile or outbound switched while connected shows up within one poll.
 * Polling stops while the screen is off and nothing is re-posted when nothing changed.
 */
class ServiceNotification(private val status: MutableLiveData<Status>, private val service: Service) : BroadcastReceiver() {
    companion object {
        private const val notificationId = 1
        private const val notificationChannel = "service"
        /** Happify: "Уведомление VPN" off — the same notification, as quiet as Android allows. */
        const val quietChannel = "service_quiet"
        /** Happify: the notification was removed (swiped or "Clear all") while the VPN runs. */
        private const val actionDeleted = "com.hiddify.app.HAPPIFY_NOTIFICATION_DELETED"
        private const val speedInterval = 1_000L
        private const val idleInterval = 5_000L
        val flags =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0

        /** Happify: the liveness traffic light (0 none, 1 green, 2 yellow, 3 red) and its short note. */
        @Volatile
        private var livenessLight = 0

        @Volatile
        private var livenessNote: String? = null

        /** The notification of the running service, to repaint it when the light changes. */
        @Volatile
        private var current: ServiceNotification? = null

        fun setLiveness(light: Int, note: String?) {
            if (light == livenessLight && note == livenessNote) return
            livenessLight = light
            livenessNote = note
            current?.repaint()
        }

        private fun lightColor(light: Int): Int? = when (light) {
            1 -> 0xFF30A46C.toInt()
            2 -> 0xFFE3A63A.toInt()
            3 -> 0xFFE5484D.toInt()
            else -> null
        }

        fun checkPermission(): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                return true
            }
            return Application.notification.areNotificationsEnabled()
        }
    }

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var pollJob: Job? = null
    private var receiverRegistered = false

    /** What is on screen right now (title, text, header); an unchanged refresh is skipped. */
    private var shown: Triple<String, String, String>? = null
    private var shownLoud = true
    private var shownLight = 0
    private var shownNote: String? = null

    /**
     * Whether the service notification is up: from [show] until [close]. A poll whose blocking
     * SystemInfo call was already in flight when the service stopped returns after [close]; with
     * this cleared, it is dropped instead of posting the notification again, which then stayed,
     * ongoing, after the VPN was stopped. Guarded by [lock], with [shown].
     */
    private var active = false
    private val lock = Any()

    private val modeLabel: String
        get() = service.getString(
            if (Settings.serviceMode == ServiceMode.VPN) R.string.mode_vpn else R.string.mode_proxy
        )

    private val notificationBuilder by lazy {
        NotificationCompat.Builder(service, notificationChannel)
            .setShowWhen(false)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSmallIcon(R.drawable.ic_stat_logo)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(
                PendingIntent.getActivity(
                    service,
                    0,
                    Intent(service, MainActivity::class.java).setFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
                    flags
                )
            )
            .setPriority(NotificationCompat.PRIORITY_LOW)
            // Happify: removed by a swipe or "Clear all", it is shown again while the VPN runs;
            // removing it never stops the VPN
            .setDeleteIntent(
                PendingIntent.getBroadcast(
                    service,
                    1,
                    Intent(actionDeleted).setPackage(Application.application.packageName),
                    flags
                )
            )
            .addAction(
                NotificationCompat.Action.Builder(
                    0, service.getText(R.string.stop), PendingIntent.getBroadcast(
                        service,
                        0,
                        Intent(Action.SERVICE_CLOSE).setPackage(Application.application.packageName),
                        flags
                    )
                ).build()
            )
            // Happify «Мимо VPN»: a small picker of the apps used last opens over the app
            .addAction(
                NotificationCompat.Action.Builder(
                    0,
                    if (java.util.Locale.getDefault().language == "ru") "Мимо VPN" else "Bypass VPN",
                    PendingIntent.getActivity(
                        service,
                        2,
                        Intent(service, MainActivity::class.java)
                            .setAction("com.hiddify.app.HAPPIFY_BYPASS")
                            .putExtra(com.hiddify.hiddify.HappifyChannel.EXTRA_ACTION, com.hiddify.hiddify.HappifyChannel.ACTION_BYPASS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
                        flags
                    )
                ).build()
            )
    }

    /** Puts the service in the foreground with a static status line (starting / connected). */
    fun show(profileName: String, @StringRes contentTextId: Int) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Application.notification.createNotificationChannel(
                NotificationChannel(notificationChannel, "hiddify service", NotificationManager.IMPORTANCE_LOW)
            )
            Application.notification.createNotificationChannel(
                NotificationChannel(quietChannel, "VPN (тихо)", NotificationManager.IMPORTANCE_MIN)
            )
        }
        synchronized(lock) {
            active = true
            current = this
            render(profileName, service.getString(contentTextId), modeLabel, foreground = true)
        }
    }

    /** Happify: the liveness light changed; the notification is painted again with it. */
    fun repaint() {
        scope.launch {
            synchronized(lock) {
                if (!active) return@synchronized
                val last = shown ?: return@synchronized
                render(last.first, last.second, last.third)
            }
        }
    }

    private fun render(profile: String, text: String, header: String, foreground: Boolean = false) {
        synchronized(lock) {
            if (!active) return
            val next = Triple(profile.ifBlank { "Hiddify" }, text, header)
            val loud = Settings.happifyVpnNotification
            val light = livenessLight
            val note = livenessNote
            if (!foreground && next == shown && loud == shownLoud && light == shownLight && note == shownNote) return
            shown = next
            shownLoud = loud
            shownLight = light
            shownNote = note
            // Happify: the liveness light, a coloured dot before the text and the accent colour;
            // with a short note («Переключаю сервер…», «Нет интернета») while something is wrong
            val color = lightColor(light)
            val body: CharSequence = if (color == null) next.second else {
                val plain = if (note.isNullOrBlank()) next.second else "$note · ${next.second}"
                android.text.SpannableString("● $plain").apply {
                    setSpan(android.text.style.ForegroundColorSpan(color), 0, 1, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
            }
            if (color != null) notificationBuilder.setColor(color) else notificationBuilder.setColor(NotificationCompat.COLOR_DEFAULT)
            val built = notificationBuilder
                .setChannelId(if (loud) notificationChannel else quietChannel)
                .setPriority(if (loud) NotificationCompat.PRIORITY_LOW else NotificationCompat.PRIORITY_MIN)
                .setContentTitle(next.first)
                .setContentText(body)
                .setSubText(next.third)
                .build()
            // Happify: "Clear all" leaves an ongoing, no-clear notification alone
            built.flags = built.flags or Notification.FLAG_ONGOING_EVENT or Notification.FLAG_NO_CLEAR
            if (foreground) service.startForeground(notificationId, built)
            else Application.notification.notify(notificationId, built)
        }
    }

    suspend fun start() {
        if (!checkPermission()) return
        startPolling()
        withContext(Dispatchers.Main) { registerReceiver() }
    }

    private fun registerReceiver() {
        if (receiverRegistered) return
        ContextCompat.registerReceiver(service, this, IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(actionDeleted)
        }, ContextCompat.RECEIVER_NOT_EXPORTED)
        receiverRegistered = true
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_SCREEN_ON -> startPolling()
            Intent.ACTION_SCREEN_OFF -> stopPolling()
            actionDeleted -> repostAfterDelete()
        }
    }

    /**
     * Happify: the user removed the notification (a swipe, or "Clear all" on Android 14+, where a
     * foreground service's notification can be dismissed). The VPN keeps running; the
     * notification comes back while it runs, unless "Уведомление VPN" is off.
     */
    private fun repostAfterDelete() {
        if (!Settings.happifyVpnNotification) return
        scope.launch {
            delay(400)
            synchronized(lock) {
                if (!active) return@synchronized
                val last = shown ?: return@synchronized
                shown = null
                render(last.first, last.second, last.third)
            }
        }
    }

    fun close() {
        stopPolling()
        synchronized(lock) {
            active = false
            shown = null
            if (current === this) current = null
            livenessLight = 0
            livenessNote = null
            ServiceCompat.stopForeground(service, ServiceCompat.STOP_FOREGROUND_REMOVE)
            // and by its id, in case a refresh reposted it with notify()
            Application.notification.cancel(notificationId)
        }
        if (receiverRegistered) {
            service.unregisterReceiver(this)
            receiverRegistered = false
        }
    }

    private fun startPolling() {
        pollJob?.cancel()
        val showSpeed = Settings.dynamicNotification
        val interval = if (showSpeed) speedInterval else idleInterval
        pollJob = scope.launch {
            val coreClient = GrpcClientProvider.grpcClient.create(CoreClient::class)
            var previous: SystemInfo? = null
            while (isActive) {
                try {
                    val info = coreClient.GetSystemInfo().executeBlocking(Empty())
                    if (!isActive) break // stopped while the call was in flight
                    update(previous, info, showSpeed)
                    previous = info
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    // The service reports Started before the core listens; keep trying.
                    Log.d("notification", "SystemInfo not available yet: ${e.message}")
                    previous = null
                }
                delay(interval)
            }
        }
    }

    private fun stopPolling() {
        pollJob?.cancel()
        pollJob = null
    }

    private fun update(previous: SystemInfo?, info: SystemInfo, showSpeed: Boolean) {
        val outbound = info.current_outbound.ifBlank { service.getString(R.string.status_started) }
        val text = if (showSpeed && previous != null) {
            val up = Libbox.formatBytes(info.uplink_total - previous.uplink_total)
            val down = Libbox.formatBytes(info.downlink_total - previous.downlink_total)
            "$outbound  ·  ↑ $up/s  ↓ $down/s"
        } else {
            outbound
        }
        render(info.current_profile, text, modeLabel)
    }
}
