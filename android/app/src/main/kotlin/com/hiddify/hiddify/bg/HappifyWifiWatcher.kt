package com.hiddify.hiddify.bg

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.hiddify.hiddify.Settings

/**
 * Happify «Автоподключение по сети» (flutter.happify_wifi_auto, off by default):
 * - the phone joins a Wi-Fi network whose name isn't trusted → the VPN starts;
 * - the phone joins a trusted Wi-Fi network (home, work) → the VPN stops;
 * - the phone is left on mobile data (no Wi-Fi) → the VPN starts.
 * Only changes of network act: a VPN the user turns off by hand on mobile data stays off until the
 * network changes. Without location access Android hides the Wi-Fi name; then only the network type
 * counts (every Wi-Fi is untrusted).
 */
object HappifyWifiWatcher {
    private const val TAG = "A/HappifyWifi"
    private const val KEY_ON = "flutter.happify_wifi_auto"
    private const val KEY_TRUSTED = "flutter.happify_trusted_wifi"

    /** What Android reports for the networks there already are when the watch begins is not a change. */
    private const val SETTLE_MS = 5_000L

    private var registered = false
    private var registeredAt = 0L
    private var handled: Network? = null
    private val wifi = mutableSetOf<Network>()
    private val cellular = mutableSetOf<Network>()
    private val main = Handler(Looper.getMainLooper())

    private fun settled() = SystemClock.elapsedRealtime() - registeredAt > SETTLE_MS

    fun register(context: Context) {
        if (registered) return
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return
        val wifiRequest = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        val wifiCallback = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            object : ConnectivityManager.NetworkCallback(FLAG_INCLUDE_LOCATION_INFO) {
                override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) =
                    onWifi(context, network, caps)

                override fun onLost(network: Network) = onWifiLost(context, network)
            }
        } else {
            object : ConnectivityManager.NetworkCallback() {
                override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) =
                    onWifi(context, network, caps)

                override fun onLost(network: Network) = onWifiLost(context, network)
            }
        }
        val cellularRequest = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        val cellularCallback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                synchronized(this@HappifyWifiWatcher) { cellular.add(network) }
                // a mobile network that comes up while no Wi-Fi is there
                main.postDelayed({ maybeStartOnMobile(context) }, 1_500)
            }

            override fun onLost(network: Network) {
                synchronized(this@HappifyWifiWatcher) { cellular.remove(network) }
            }
        }
        runCatching {
            registeredAt = SystemClock.elapsedRealtime()
            cm.registerNetworkCallback(wifiRequest, wifiCallback)
            registered = true
            cm.registerNetworkCallback(cellularRequest, cellularCallback)
        }.onFailure { Log.w(TAG, "register failed", it) }
    }

    /** Last name the watcher's own callback (FLAG_INCLUDE_LOCATION_INFO) saw, per Wi-Fi network. */
    private val names = mutableMapOf<Network, String>()

    private fun clean(raw: String?): String? {
        val name = raw?.trim()?.removeSurrounding("\"")
        return if (name.isNullOrEmpty() || name == "<unknown ssid>" || name == "0x") null else name
    }

    /**
     * The Wi-Fi network under the VPN: with the VPN on, the active network is the VPN itself, so
     * the Wi-Fi is looked up among all networks (TRANSPORT_WIFI without TRANSPORT_VPN).
     */
    fun underlyingWifi(context: Context): Pair<Network, NetworkCapabilities>? {
        val cm = context.applicationContext.getSystemService(ConnectivityManager::class.java) ?: return null
        @Suppress("DEPRECATION")
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return network to caps
        }
        return null
    }

    fun hasLocationPermission(context: Context): Boolean =
        androidx.core.content.ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_FINE_LOCATION) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED

    fun locationEnabled(context: Context): Boolean = runCatching {
        val lm = context.applicationContext.getSystemService(android.location.LocationManager::class.java) ?: return true
        androidx.core.location.LocationManagerCompat.isLocationEnabled(lm)
    }.getOrDefault(true)

    /**
     * The name of the Wi-Fi under the VPN, asked the way Android 12+ wants it: a one-shot callback
     * with FLAG_INCLUDE_LOCATION_INFO (the plain capabilities and WifiManager.connectionInfo hide it
     * there). Blocks up to [waitMs]; call it off the main thread.
     */
    private fun askSsid(context: Context, waitMs: Long): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return null
        val cm = context.applicationContext.getSystemService(ConnectivityManager::class.java) ?: return null
        val latch = java.util.concurrent.CountDownLatch(1)
        var found: String? = null
        val callback = object : ConnectivityManager.NetworkCallback(FLAG_INCLUDE_LOCATION_INFO) {
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return
                val name = clean((caps.transportInfo as? WifiInfo)?.ssid)
                if (name != null) {
                    found = name
                    latch.countDown()
                }
            }
        }
        val request = NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build()
        return runCatching {
            cm.registerNetworkCallback(request, callback)
            try {
                latch.await(waitMs, java.util.concurrent.TimeUnit.MILLISECONDS)
            } finally {
                runCatching { cm.unregisterNetworkCallback(callback) }
            }
            found
        }.getOrNull()
    }

    /** The current Wi-Fi name, or null when not on Wi-Fi or the name is hidden. */
    fun currentSsid(context: Context, caps: NetworkCapabilities? = null, waitMs: Long = 0): String? {
        val wifi = caps?.let { null to it } ?: underlyingWifi(context)
        if (wifi == null) return null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            clean((wifi.second.transportInfo as? WifiInfo)?.ssid)?.let { return it }
        }
        wifi.first?.let { network -> synchronized(this) { names[network] }?.let { return it } }
        if (waitMs > 0) askSsid(context, waitMs)?.let { return it }
        @Suppress("DEPRECATION")
        return clean(context.applicationContext.getSystemService(WifiManager::class.java)?.connectionInfo?.ssid)
    }

    /**
     * For the «Доверенные Wi-Fi» dialog: whether the phone is on Wi-Fi under the VPN, its name, and
     * why the name is hidden when it is (no location access, or location turned off).
     */
    fun state(context: Context): Map<String, Any?> {
        val onWifi = underlyingWifi(context) != null
        val permission = hasLocationPermission(context)
        val location = locationEnabled(context)
        val ssid = if (onWifi) currentSsid(context, waitMs = 1_500) else null
        return mapOf("wifi" to onWifi, "ssid" to ssid, "permission" to permission, "location" to location)
    }

    private fun enabled(context: Context): Boolean =
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).getBoolean(KEY_ON, false)

    private fun trusted(context: Context): List<String> =
        (context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).getString(KEY_TRUSTED, "") ?: "")
            .split('\n').map { it.trim() }.filter { it.isNotEmpty() }

    private fun onWifi(context: Context, network: Network, caps: NetworkCapabilities) {
        // the request excludes VPNs (NOT_VPN by default); never act on the tunnel itself
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return
        val seen = currentSsid(context, caps)
        synchronized(this) {
            wifi.add(network)
            if (seen != null) names[network] = seen
        }
        if (handled == network) return
        if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return
        handled = network
        if (!enabled(context) || !settled()) return
        val ssid = seen
        if (ssid != null && ssid in trusted(context)) {
            if (VPNService.current == null) return
            Log.d(TAG, "trusted Wi-Fi $ssid: stopping the VPN")
            main.post {
                runCatching {
                    // a stop by the network, not a failure: nothing brings it back until the network changes
                    Settings.startedByUser = false
                    BoxService.stop()
                }.onFailure { Log.w(TAG, "stop failed", it) }
            }
            return
        }
        Log.d(TAG, "untrusted Wi-Fi ${ssid ?: "(name hidden)"}: starting the VPN")
        start()
    }

    private fun onWifiLost(context: Context, network: Network) {
        if (handled == network) handled = null
        val left = synchronized(this) {
            wifi.remove(network)
            names.remove(network)
            wifi.isEmpty() && cellular.isNotEmpty()
        }
        // off the Wi-Fi onto mobile data
        if (left) main.postDelayed({ maybeStartOnMobile(context) }, 1_500)
    }

    private fun maybeStartOnMobile(context: Context) {
        val onMobileOnly = synchronized(this) { wifi.isEmpty() && cellular.isNotEmpty() }
        if (!onMobileOnly || !enabled(context) || !settled()) return
        Log.d(TAG, "mobile data: starting the VPN")
        start()
    }

    private fun start() {
        if (VPNService.current != null) return
        main.post {
            runCatching {
                if (VPNService.current != null) return@runCatching
                Settings.startedByUser = true
                Settings.startCoreAfterStartingService = true
                BoxService.start()
            }.onFailure { Log.w(TAG, "start failed", it) }
        }
    }
}
