package com.hiddify.hiddify

import android.app.AppOpsManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.usage.UsageStatsManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.hiddify.hiddify.bg.ServiceNotification
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/**
 * Happify's reliability features, the Android side (lib/features/happ/reliability/happ_platform.dart):
 * - the screen going on and off, so the liveness probe runs only while someone looks;
 * - the colour of the VPN notification (the liveness traffic light);
 * - «Уведомления»: posting them on two channels, important (with sound) and quiet;
 * - «Мимо VPN»: the apps used last (UsageStatsManager, with «Доступ к истории использования»),
 *   the launchable apps and their names; the action from the VPN notification.
 */
class HappifyChannel : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val TAG = "A/HappifyChannel"
        const val channelName = "com.hiddify.app/happify"
        const val CHANNEL_ALERTS = "happify_alerts"
        const val CHANNEL_EVENTS = "happify_events"

        /** The intent extra of the VPN notification's «Мимо VPN» action. */
        const val EXTRA_ACTION = "happify_action"
        const val ACTION_BYPASS = "bypass"

        @Volatile
        var instance: HappifyChannel? = null

        /** An action asked for before the Flutter side could hear it; taken once ("take_action"). */
        @Volatile
        var pendingAction: String? = null

        /** From an intent of the running activity: told to the Flutter side at once, else kept. */
        fun deliverAction(action: String) {
            val channel = instance
            if (channel == null || !channel.post("action", action)) pendingAction = action
        }

        private val ru: Boolean get() = Locale.getDefault().language == "ru"
    }

    private var channel: MethodChannel? = null
    private var context: Context? = null
    private val main = Handler(Looper.getMainLooper())
    private var receiverRegistered = false

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Intent.ACTION_SCREEN_ON -> post("screen", true)
                Intent.ACTION_SCREEN_OFF -> post("screen", false)
            }
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, channelName).also { it.setMethodCallHandler(this) }
        instance = this
        runCatching {
            ContextCompat.registerReceiver(
                binding.applicationContext,
                screenReceiver,
                IntentFilter().apply {
                    addAction(Intent.ACTION_SCREEN_ON)
                    addAction(Intent.ACTION_SCREEN_OFF)
                },
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
            receiverRegistered = true
        }.onFailure { Log.w(TAG, "screen receiver", it) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        if (receiverRegistered) {
            runCatching { binding.applicationContext.unregisterReceiver(screenReceiver) }
            receiverRegistered = false
        }
        if (instance === this) instance = null
        context = null
    }

    /** Calls the Flutter side on the main thread; false when it is gone. */
    fun post(method: String, arguments: Any?): Boolean {
        val c = channel ?: return false
        main.post { runCatching { c.invokeMethod(method, arguments) } }
        return true
    }

    /** Runs [work] off the main thread and answers on it. */
    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        Thread {
            val outcome = runCatching(work)
            main.post {
                outcome.onSuccess { result.success(it) }
                    .onFailure { result.error("happify", it.message, null) }
            }
        }.start()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context ?: return result.error("happify", "detached", null)
        when (call.method) {
            "screen_on" -> result.success(
                (ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager)?.isInteractive ?: true
            )

            "take_action" -> {
                val action = pendingAction
                pendingAction = null
                result.success(action)
            }

            "liveness" -> {
                val light = (call.argument<Number>("light"))?.toInt() ?: 0
                ServiceNotification.setLiveness(light, call.argument<String>("note"))
                result.success(null)
            }

            "notify" -> result.success(
                runCatching {
                    postNotification(
                        ctx,
                        id = call.argument<Number>("id")?.toInt() ?: 7000,
                        title = call.argument<String>("title") ?: "",
                        text = call.argument<String>("text") ?: "",
                        important = call.argument<Boolean>("important") ?: false,
                    )
                }.onFailure { Log.w(TAG, "notify", it) }.getOrDefault(false)
            )

            "has_usage_access" -> result.success(hasUsageAccess(ctx))

            "open_usage_settings" -> {
                runCatching {
                    ctx.startActivity(
                        Intent(android.provider.Settings.ACTION_USAGE_ACCESS_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                }.onFailure { Log.w(TAG, "usage settings", it) }
                result.success(null)
            }

            "recent_apps" -> {
                val count = call.argument<Number>("count")?.toInt() ?: 5
                background(result) { recentApps(ctx, count) }
            }

            "launchable_apps" -> background(result) { launchableApps(ctx) }

            "app_labels" -> {
                val packages = call.argument<List<String>>("packages") ?: emptyList()
                background(result) {
                    val pm = ctx.packageManager
                    packages.associateWith { pkg ->
                        runCatching { pm.getApplicationInfo(pkg, 0).loadLabel(pm).toString() }.getOrDefault(pkg)
                    }
                }
            }

            else -> result.notImplemented()
        }
    }

    private fun postNotification(ctx: Context, id: Int, title: String, text: String, important: Boolean): Boolean {
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ALERTS,
                    if (ru) "Важные уведомления" else "Important",
                    NotificationManager.IMPORTANCE_DEFAULT,
                )
            )
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_EVENTS,
                    if (ru) "События" else "Events",
                    NotificationManager.IMPORTANCE_LOW,
                )
            )
        }
        // Android 13+: nothing shows without the notification permission
        if (!nm.areNotificationsEnabled()) return false
        val open = PendingIntent.getActivity(
            ctx,
            3,
            Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0,
        )
        val notification = NotificationCompat.Builder(ctx, if (important) CHANNEL_ALERTS else CHANNEL_EVENTS)
            .setSmallIcon(R.drawable.ic_stat_logo)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setPriority(if (important) NotificationCompat.PRIORITY_DEFAULT else NotificationCompat.PRIORITY_LOW)
            .setAutoCancel(true)
            .setContentIntent(open)
            .build()
        nm.notify(id, notification)
        return true
    }

    private fun hasUsageAccess(ctx: Context): Boolean {
        val ops = ctx.getSystemService(Context.APP_OPS_SERVICE) as? AppOpsManager ?: return false
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), ctx.packageName)
        } else {
            @Suppress("DEPRECATION")
            ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), ctx.packageName)
        }
        if (mode == AppOpsManager.MODE_DEFAULT) {
            return ctx.checkCallingOrSelfPermission(android.Manifest.permission.PACKAGE_USAGE_STATS) ==
                PackageManager.PERMISSION_GRANTED
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    /** Packages a user would never mean: this app, the launcher, the system UI, settings. */
    private fun skipped(ctx: Context): Set<String> {
        val pm = ctx.packageManager
        val home = runCatching {
            pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME), 0)
                .map { it.activityInfo.packageName }
        }.getOrDefault(emptyList())
        return (home + listOf(ctx.packageName, "com.android.systemui", "com.android.settings", "android")).toSet()
    }

    private fun recentApps(ctx: Context, count: Int): List<Map<String, String>> {
        if (!hasUsageAccess(ctx)) return emptyList()
        val usage = ctx.getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager ?: return emptyList()
        val pm = ctx.packageManager
        val now = System.currentTimeMillis()
        val stats = usage.queryUsageStats(UsageStatsManager.INTERVAL_DAILY, now - 2 * 24 * 3600_000L, now) ?: return emptyList()
        val skip = skipped(ctx)
        val bypassed = Settings.happifyBypassApps.toSet()
        return stats
            .filter { it.lastTimeUsed > 0 && it.packageName !in skip && it.packageName !in bypassed }
            .groupBy { it.packageName }
            .map { (pkg, list) -> pkg to list.maxOf { it.lastTimeUsed } }
            .sortedByDescending { it.second }
            .asSequence()
            .filter { (pkg, _) -> pm.getLaunchIntentForPackage(pkg) != null }
            .take(count)
            .map { (pkg, _) ->
                mapOf(
                    "package" to pkg,
                    "name" to runCatching { pm.getApplicationInfo(pkg, 0).loadLabel(pm).toString() }.getOrDefault(pkg),
                )
            }
            .toList()
    }

    private fun launchableApps(ctx: Context): List<Map<String, String>> {
        val pm = ctx.packageManager
        val skip = skipped(ctx)
        val bypassed = Settings.happifyBypassApps.toSet()
        return pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)
            .asSequence()
            .map { it.activityInfo.packageName }
            .distinct()
            .filter { it !in skip && it !in bypassed }
            .map { pkg ->
                mapOf(
                    "package" to pkg,
                    "name" to runCatching { pm.getApplicationInfo(pkg, 0).loadLabel(pm).toString() }.getOrDefault(pkg),
                )
            }
            .sortedBy { it["name"]?.lowercase() }
            .toList()
    }
}
