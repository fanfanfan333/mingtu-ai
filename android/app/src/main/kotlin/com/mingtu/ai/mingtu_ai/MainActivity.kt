package com.mingtu.ai.mingtu_ai

import android.content.Context
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
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
        // control fall back to timings only; devices without
        // a vibrator simply no-op.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mingtu/device")
            .setMethodCallHandler { call, result ->
                if (call.method == "vibratePattern") {
                    val timings = (call.argument<List<Number>>("timings") ?: emptyList())
                        .map { it.toLong() }
                        .toLongArray()
                    val amplitudes = call.argument<List<Number>>("amplitudes")
                        ?.map { it.toInt() }
                        ?.toIntArray()
                    vibratePattern(timings, amplitudes)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun vibratePattern(timings: LongArray, amplitudes: IntArray?) {
        if (timings.isEmpty()) return
        val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator ?: return
        if (!vibrator.hasVibrator()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val effect = if (amplitudes != null &&
                amplitudes.size == timings.size &&
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
    }
}
