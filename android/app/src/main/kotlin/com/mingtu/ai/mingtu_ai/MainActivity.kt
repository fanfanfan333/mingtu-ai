package com.mingtu.ai.mingtu_ai

import android.content.Context
import android.os.Build
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    // The mingtu/device channel instance, kept so the
    // thermal monitor (below) can PUSH status changes back
    // to Dart as onThermalStatus calls on the same channel.
    private var deviceChannel: MethodChannel? = null

    // The registered PowerManager thermal listener, or null
    // while monitoring is off (always null below API 29,
    // where the platform has no thermal status API).
    private var thermalListener: PowerManager.OnThermalStatusChangedListener? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // mingtu/device: the app's own device channel. It
        // carries the NAVHAZ vibration patterns (spec
        // section 2.5): the Dart side sends parallel
        // timings/amplitudes arrays and the waveform is
        // played with VibrationEffect. Devices without
        // amplitude control fall back to timings only.
        // M2 section 3.2 adds the thermal feed on the SAME
        // channel (see the thermal methods below).
        //
        // Result contract (M1 fix round): the handler answers
        // a Boolean -- true only when the pattern was handed
        // to the vibrator, false when it was NOT executed
        // (invalid arguments, no vibrator, SecurityException
        // from a missing VIBRATE permission, or an
        // IllegalArgumentException from the waveform API).
        // Failure is reported, never faked as success and
        // never thrown across the channel.
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, "mingtu/device"
        )
        deviceChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "vibratePattern" -> {
                    val timings = call.argument<List<Number>>("timings")
                        ?.map { it.toLong() }
                        ?.toLongArray()
                    val amplitudes = call.argument<List<Number>>("amplitudes")
                        ?.map { it.toInt() }
                        ?.toIntArray()
                    result.success(vibratePattern(timings, amplitudes))
                }
                "startThermalMonitoring" -> startThermalMonitoring(result)
                "stopThermalMonitoring" -> {
                    stopThermalMonitoring()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // ---- Thermal status (M2 section 3.2) --------------------
    //
    // Payload contract (mirrored in Dart, core/thermal.dart):
    // a map with "status" (the PowerManager THERMAL_STATUS_*
    // integer) and "headroom" (a Double forecast in 0..1, or
    // null). startThermalMonitoring answers with the CURRENT
    // payload; every later status change is pushed to Dart as
    // an onThermalStatus call carrying the same payload.
    //
    // API gating (minSdk is 24): the thermal status API
    // exists only from API 29, getThermalHeadroom only from
    // API 30. Below 29 nothing is registered and the answer
    // is the unknown payload (status -1, headroom null) --
    // the Dart side maps that to its unknown status and
    // imposes no cap. Every failure path (no PowerManager,
    // SecurityException, any platform exception) degrades to
    // the same unknown payload: heat that cannot be read
    // must never crash the app or fabricate a reading, and
    // nothing here ever throws across the channel.

    private fun thermalPayload(status: Int): Map<String, Any?> {
        var headroom: Double? = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            headroom = try {
                val powerManager =
                    getSystemService(Context.POWER_SERVICE) as? PowerManager
                // 10-second forecast horizon.
                val value = powerManager?.getThermalHeadroom(10)
                if (value != null && !value.isNaN()) value.toDouble() else null
            } catch (e: Exception) {
                null
            }
        }
        return mapOf("status" to status, "headroom" to headroom)
    }

    private fun unknownThermalPayload(): Map<String, Any?> =
        mapOf("status" to -1, "headroom" to null)

    private fun startThermalMonitoring(result: MethodChannel.Result) {
        // The payload is computed FIRST (every failure path
        // inside degrades to the unknown payload), so the
        // channel result is answered exactly once, here.
        result.success(subscribeThermalAndCurrentPayload())
    }

    private fun subscribeThermalAndCurrentPayload(): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return unknownThermalPayload()
        }
        return try {
            val powerManager =
                getSystemService(Context.POWER_SERVICE) as? PowerManager
                    ?: return unknownThermalPayload()
            if (thermalListener == null) {
                val listener =
                    PowerManager.OnThermalStatusChangedListener { status ->
                        try {
                            deviceChannel?.invokeMethod(
                                "onThermalStatus", thermalPayload(status)
                            )
                        } catch (e: Exception) {
                            Log.w(
                                "MingtuDevice",
                                "onThermalStatus push failed", e
                            )
                        }
                    }
                thermalListener = listener
                powerManager.addThermalStatusListener(
                    java.util.concurrent.Executors.newSingleThreadExecutor(),
                    listener
                )
            }
            thermalPayload(powerManager.currentThermalStatus)
        } catch (e: Exception) {
            Log.w("MingtuDevice", "startThermalMonitoring failed", e)
            unknownThermalPayload()
        }
    }

    private fun stopThermalMonitoring() {
        val listener = thermalListener ?: return
        thermalListener = null
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        try {
            val powerManager =
                getSystemService(Context.POWER_SERVICE) as? PowerManager
            powerManager?.removeThermalStatusListener(listener)
        } catch (e: Exception) {
            Log.w("MingtuDevice", "stopThermalMonitoring failed", e)
        }
    }

    /**
     * Validate, then vibrate. Returns true only when the
     * pattern was actually handed to the vibrator.
     *
     * Validation (any failure -> false, nothing played):
     * timings null or empty; amplitudes present but a
     * different length than timings; any timing negative;
     * any amplitude outside 0..255.
     */
    private fun vibratePattern(timings: LongArray?, amplitudes: IntArray?): Boolean {
        if (timings == null || timings.isEmpty()) return false
        if (amplitudes != null && amplitudes.size != timings.size) return false
        if (timings.any { it < 0L }) return false
        if (amplitudes != null && amplitudes.any { it < 0 || it > 255 }) return false
        val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            ?: return false
        if (!vibrator.hasVibrator()) return false
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val effect = if (amplitudes != null &&
                    vibrator.hasAmplitudeControl()
                ) {
                    VibrationEffect.createWaveform(timings, amplitudes, -1)
                } else {
                    VibrationEffect.createWaveform(timings, -1)
                }
                vibrator.vibrate(effect)
            } else {
                // Pre-API-26 fallback: timings only, no amplitudes.
                @Suppress("DEPRECATION")
                vibrator.vibrate(timings, -1)
            }
            true
        } catch (e: SecurityException) {
            // VIBRATE permission not granted: report failure
            // through the channel instead of crashing.
            Log.w("MingtuDevice", "vibratePattern: permission denied", e)
            false
        } catch (e: IllegalArgumentException) {
            // The waveform API rejected the pattern despite
            // the validation above (e.g. platform quirks).
            Log.w("MingtuDevice", "vibratePattern: invalid pattern", e)
            false
        }
    }
}
