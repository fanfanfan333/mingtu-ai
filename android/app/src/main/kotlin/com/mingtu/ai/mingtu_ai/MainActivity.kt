package com.mingtu.ai.mingtu_ai

import android.content.Context
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // mingtu/device: the app's own device channel. For now
        // it carries only the NAVHAZ vibration patterns
        // (spec section 2.5): the Dart side sends parallel
        // timings/amplitudes arrays and the waveform is played
        // with VibrationEffect. Devices without amplitude
        // control fall back to timings only.
        //
        // Result contract (M1 fix round): the handler answers
        // a Boolean -- true only when the pattern was handed
        // to the vibrator, false when it was NOT executed
        // (invalid arguments, no vibrator, SecurityException
        // from a missing VIBRATE permission, or an
        // IllegalArgumentException from the waveform API).
        // Failure is reported, never faked as success and
        // never thrown across the channel.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mingtu/device")
            .setMethodCallHandler { call, result ->
                if (call.method == "vibratePattern") {
                    val timings = call.argument<List<Number>>("timings")
                        ?.map { it.toLong() }
                        ?.toLongArray()
                    val amplitudes = call.argument<List<Number>>("amplitudes")
                        ?.map { it.toInt() }
                        ?.toIntArray()
                    result.success(vibratePattern(timings, amplitudes))
                } else {
                    result.notImplemented()
                }
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
