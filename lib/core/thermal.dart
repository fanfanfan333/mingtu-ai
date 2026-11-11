/// Device thermal status for derating (NAVHAZ M2 spec
/// section 3.2): the status vocabulary + the monitor seam.
///
/// The values mirror Android's PowerManager thermal
/// status constants one to one (THERMAL_STATUS_NONE = 0
/// through THERMAL_STATUS_SHUTDOWN = 6); [unknown] is the
/// fail-closed local addition for every case where the
/// platform offers no reading at all -- API level below
/// 29, a missing PowerManager, or any platform error.
/// Unknown NEVER constrains anything: a device that
/// cannot report its heat is treated exactly like a cool
/// device, never punished for the missing sensor path.
library;

import 'dart:async';

/// Thermal status, mirroring the platform constants.
enum ThermalStatus {
  none,
  light,
  moderate,
  severe,
  critical,
  emergency,
  shutdown,
  unknown,
}

/// Map a raw platform thermal-status integer onto the
/// enum. Anything outside 0..6 (including the -1 the
/// native side answers below API 29, and null) maps to
/// [ThermalStatus.unknown].
ThermalStatus thermalStatusFromPlatformValue(int? value) =>
    switch (value) {
      0 => ThermalStatus.none,
      1 => ThermalStatus.light,
      2 => ThermalStatus.moderate,
      3 => ThermalStatus.severe,
      4 => ThermalStatus.critical,
      5 => ThermalStatus.emergency,
      6 => ThermalStatus.shutdown,
      _ => ThermalStatus.unknown,
    };

/// The integer payload key set the native side uses when
/// it pushes a status event over the device channel, and
/// the keys of the map it answers a subscription request
/// with. Kept here (not in the adapter) so the contract
/// has exactly one written home.
const String thermalStatusPayloadKey = 'status';
const String thermalHeadroomPayloadKey = 'headroom';

/// Decode one channel payload (a status integer, or a map
/// carrying one under [thermalStatusPayloadKey]) into a
/// status. Malformed payloads decode to unknown: a garbled
/// event must never turn into a fabricated reading.
ThermalStatus thermalStatusFromPayload(Object? payload) {
  if (payload is int) return thermalStatusFromPlatformValue(payload);
  if (payload is Map) {
    final Object? raw = payload[thermalStatusPayloadKey];
    if (raw is num) return thermalStatusFromPlatformValue(raw.toInt());
  }
  return ThermalStatus.unknown;
}

/// Decode the thermal headroom riding along in a payload
/// map (API 30+ on the native side; a 0..1 forecast where
/// 1 means throttling is imminent). Absent, malformed or
/// NaN values decode to null -- headroom is advisory only
/// and never gates anything by itself.
double? thermalHeadroomFromPayload(Object? payload) {
  if (payload is Map) {
    final Object? raw = payload[thermalHeadroomPayloadKey];
    if (raw is num) {
      final double value = raw.toDouble();
      if (!value.isNaN) return value;
    }
  }
  return null;
}

/// Platform seam: a stream of thermal status changes plus
/// the latest known status. Implementations PUSH events as
/// the platform reports them; there is no polling at this
/// layer.
abstract class ThermalMonitor {
  /// Status changes as they are reported. The current
  /// status is also delivered once when the subscription
  /// starts (the native side answers the start request
  /// with its current reading).
  Stream<ThermalStatus> get statuses;

  /// The most recent status, [ThermalStatus.unknown]
  /// before the first reading.
  ThermalStatus get currentStatus;

  /// The most recent headroom forecast (0..1), or null
  /// when the platform offered none.
  double? get currentHeadroom;

  void start();
  void dispose();
}

/// Fail-closed monitor: the status stays unknown forever
/// and nothing is ever constrained on its account.
class UnavailableThermalMonitor implements ThermalMonitor {
  const UnavailableThermalMonitor();

  @override
  Stream<ThermalStatus> get statuses => const Stream<ThermalStatus>.empty();

  @override
  ThermalStatus get currentStatus => ThermalStatus.unknown;

  @override
  double? get currentHeadroom => null;

  @override
  void start() {}

  @override
  void dispose() {}
}
