/// Permission gateway factory (UI-A11Y UI-06).
///
/// Conditional export, same pattern as voice_recorder.dart:
/// on a phone (dart:io) the permission_handler-backed
/// implementation is used; elsewhere the unavailable
/// implementation reports no permission system, so the
/// all-voice permission flow never starts off-device. The
/// contract is [PermissionGateway] in
/// core/permission_flow.dart; tests substitute fakes
/// through the debug seam, never the platform channel.
library;

import '../core/permission_flow.dart';

export 'permission_gateway_stub.dart'
    if (dart.library.io) 'permission_gateway_mobile.dart';

/// Off-device fallback: no platform permission system
/// exists here, so nothing can be asked or checked. The
/// flow gated on [isAvailable] therefore never runs; the
/// individual answers stay plain denials (never a fake
/// grant).
class UnavailablePermissionGateway implements PermissionGateway {
  const UnavailablePermissionGateway();

  @override
  bool get isAvailable => false;

  @override
  Future<PermissionOutcome> request(GuidePermission permission) async =>
      PermissionOutcome.denied;

  @override
  Future<PermissionOutcome> status(GuidePermission permission) async =>
      PermissionOutcome.denied;

  @override
  Future<void> openSettings() async {}
}
