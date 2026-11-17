package com.hiddify.hiddify.bg

import android.util.Log
import kotlinx.coroutines.delay

/**
 * Set by the app while the speedometer runs its proxy-only test core (nothing connected). The
 * core is one instance per process, so a VPN start the service makes by itself (untrusted Wi-Fi,
 * boot) waits until the app has stopped the test core and put the real settings back.
 */
object HappifyPingLock {
    private const val TAG = "A/HappifyPingLock"

    @Volatile
    var active = false

    suspend fun awaitFree(maxMs: Long = 20_000L) {
        if (!active) return
        Log.i(TAG, "waiting for the ping test to stop before starting")
        val start = System.currentTimeMillis()
        while (active && System.currentTimeMillis() - start < maxMs) delay(100)
        if (active) {
            Log.w(TAG, "ping test still running after ${maxMs}ms; starting anyway")
            active = false
        }
    }
}
