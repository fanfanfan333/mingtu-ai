import 'dart:async';

import 'package:wakelock_plus/wakelock_plus.dart';

abstract class WakelockGateway {
  Future<void> setEnabled(bool enabled);
}

class PluginWakelockGateway implements WakelockGateway {
  @override
  Future<void> setEnabled(bool enabled) => WakelockPlus.toggle(enable: enabled);
}

/// Serializes platform calls, including transitions made while a call is in flight.
class WakelockControl {
  WakelockControl(this.gateway);
  final WakelockGateway gateway;
  bool? _requested;
  Future<void> _pending = Future<void>.value();

  Future<void> update(
      {required bool foreground,
      required bool camera,
      required bool navigation,
      required bool listening}) {
    final bool desired = foreground && (camera || navigation || listening);
    if (_requested == desired) return _pending;
    _requested = desired;
    _pending = _pending.then((_) async {
      try {
        await gateway.setEnabled(desired);
      } catch (_) {
        // The plugin may not exist on this platform.
        if (_requested == desired) _requested = null;
      }
    });
    return _pending;
  }
}
