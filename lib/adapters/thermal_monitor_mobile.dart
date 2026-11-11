import 'dart:async';

import 'package:flutter/services.dart';

import '../core/thermal.dart';

/// Device thermal monitor over the app's own
/// `mingtu/device` MethodChannel (MainActivity.kt) --
/// the channel the NAVHAZ vibration patterns already use.
///
/// The channel pattern in this app is MethodChannel-only
/// (no EventChannel exists anywhere in the codebase), so
/// the push-shaped thermal feed rides the closest
/// existing pattern: Dart asks the native side to start
/// (`startThermalMonitoring`) and stop
/// (`stopThermalMonitoring`) the PowerManager listener,
/// the native side answers the start call with its
/// current reading, and every later status change is
/// pushed back as an `onThermalStatus` method call on the
/// same channel. Payloads are maps carrying the platform
/// status integer and, on API 30+, the headroom forecast
/// (see core/thermal.dart for the payload contract).
///
/// Platform floor, honestly scoped: below API 29 Android
/// has no thermal status API at all, so the native side
/// registers nothing and answers with an unknown payload
/// -- the status here stays [ThermalStatus.unknown] and
/// derating never engages. Every channel failure degrades
/// the same way: a thermal feed that cannot be read must
/// never crash the app or invent a reading.
class DeviceThermalMonitor implements ThermalMonitor {
  static const MethodChannel _channel = MethodChannel('mingtu/device');

  final StreamController<ThermalStatus> _events =
      StreamController<ThermalStatus>.broadcast();
  ThermalStatus _current = ThermalStatus.unknown;
  double? _headroom;
  bool _started = false;
  bool _disposed = false;

  @override
  Stream<ThermalStatus> get statuses => _events.stream;

  @override
  ThermalStatus get currentStatus => _current;

  @override
  double? get currentHeadroom => _headroom;

  @override
  void start() {
    if (_started || _disposed) return;
    _started = true;
    _channel.setMethodCallHandler(_onNativeCall);
    unawaited(_requestStart());
  }

  Future<void> _requestStart() async {
    try {
      final Object? payload =
          await _channel.invokeMethod<Object?>('startThermalMonitoring');
      _ingest(payload);
    } catch (_) {
      // No channel / platform error: stay unknown.
      _ingest(null);
    }
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    if (call.method == 'onThermalStatus') {
      _ingest(call.arguments);
    }
    return null;
  }

  void _ingest(Object? payload) {
    if (_disposed) return;
    _headroom = thermalHeadroomFromPayload(payload) ?? _headroom;
    final ThermalStatus next = thermalStatusFromPayload(payload);
    if (next == _current) return;
    _current = next;
    _events.add(next);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_started) {
      _channel.setMethodCallHandler(null);
      unawaited(() async {
        try {
          await _channel.invokeMethod<Object?>('stopThermalMonitoring');
        } catch (_) {
          // Already gone natively or no channel: nothing
          // to release that silence would not cover.
        }
      }());
    }
    unawaited(_events.close());
  }
}

ThermalMonitor createThermalMonitor() => DeviceThermalMonitor();
