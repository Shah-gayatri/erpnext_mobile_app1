package com.example.frappe_hr_webview // <-- KEEP your existing package name here

import android.Manifest
import android.content.pm.PackageManager
import android.content.Context
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "device_security"

    // Maximum time we'll wait for a GPS fix before giving up.
    // Without this, a weak/cold GPS signal can block app startup for
    // minutes, which is very likely what you're experiencing.
    private val MOCK_LOCATION_TIMEOUT_MS = 4000L

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isDeveloperModeOn" -> {
                    val isDevMode = Settings.Secure.getInt(
                        contentResolver,
                        Settings.Global.DEVELOPMENT_SETTINGS_ENABLED,
                        0
                    ) != 0
                    result.success(isDevMode)
                }
                "isVpnActive" -> {
                    result.success(isVpnActive())
                }
                "isMockLocationOn" -> {
                    checkMockLocation(result)
                }
                "getAndroidId" -> {
                    result.success(getAndroidId())
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun getAndroidId(): String {
        return Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID) ?: ""
    }

    private fun isVpnActive(): Boolean {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = cm.activeNetwork ?: return false
        val capabilities = cm.getNetworkCapabilities(network) ?: return false
        return capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
    }

    // Requests one GPS fix and checks if it's flagged as coming from a
    // mock/fake-GPS app. Now with a hard timeout so a weak/cold GPS signal
    // can never block the app for more than a few seconds.
    private fun checkMockLocation(result: MethodChannel.Result) {
        if (ActivityCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION)
            != PackageManager.PERMISSION_GRANTED
        ) {
            // Can't check without permission — treat as "not mocked" so app isn't wrongly blocked
            result.success(false)
            return
        }

        val locationManager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val handler = Handler(Looper.getMainLooper())
        var resultAlreadySent = false

        // Fastest path: use the last known location first (cached, instant)
        // instead of always waiting for a brand-new fix.
        try {
            val lastKnown = locationManager.getLastKnownLocation(LocationManager.GPS_PROVIDER)
                ?: locationManager.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)

            if (lastKnown != null) {
                val isMock = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    lastKnown.isMock
                } else {
                    @Suppress("DEPRECATION")
                    lastKnown.isFromMockProvider
                }
                result.success(isMock)
                return
            }
        } catch (e: Exception) {
            // fall through to requesting a fresh fix below
        }

        // No cached location available — request a fresh fix, but give up
        // after MOCK_LOCATION_TIMEOUT_MS instead of waiting indefinitely.
        val listener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                if (resultAlreadySent) return
                resultAlreadySent = true
                locationManager.removeUpdates(this)

                val isMock = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    location.isMock
                } else {
                    @Suppress("DEPRECATION")
                    location.isFromMockProvider
                }
                result.success(isMock)
            }
            override fun onProviderDisabled(provider: String) {}
            override fun onProviderEnabled(provider: String) {}
            @Deprecated("Deprecated in Java")
            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
        }

        val timeoutRunnable = Runnable {
            if (!resultAlreadySent) {
                resultAlreadySent = true
                locationManager.removeUpdates(listener)
                // Timed out — assume "not mocked" rather than blocking the user.
                result.success(false)
            }
        }

        try {
            locationManager.requestSingleUpdate(
                LocationManager.GPS_PROVIDER,
                listener,
                Looper.getMainLooper()
            )
            handler.postDelayed(timeoutRunnable, MOCK_LOCATION_TIMEOUT_MS)
        } catch (e: Exception) {
            if (!resultAlreadySent) {
                resultAlreadySent = true
                result.success(false)
            }
        }
    }
}