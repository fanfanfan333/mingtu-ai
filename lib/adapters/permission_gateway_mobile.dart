/// Phone permission gateway (permission_handler 13.0.2,
/// MIT -- see pubspec.yaml).
///
/// Maps the plugin's statuses onto the flow's three
/// outcomes:
///   granted / limited / provisional -> granted
///     (limited location is approximate location: the user
///     did grant; provisional is a granted trial state)
///   denied -> denied (it can be asked again)
///   permanentlyDenied -> permanentlyDenied
///   restricted -> permanentlyDenied (a system-level
///     block the dialog cannot lift; the settings page is
///     the only remedy, which is the flow's branch for it)
///
/// The deferred background step is NEVER requested from
/// the platform in this phase: request() answers it with a
/// plain denial without touching the plugin, and the
/// flow's step list never contains it anyway.
library;

import 'dart:io' show Platform;

import 'package:permission_handler/permission_handler.dart' as ph;

import '../core/permission_flow.dart';
import '../config/app_config.dart';

PermissionGateway createPermissionGateway() => PermissionHandlerGateway();

class PermissionHandlerGateway implements PermissionGateway {
  @override
  bool get isAvailable => Platform.isAndroid || Platform.isIOS;

  ph.Permission _pluginPermission(GuidePermission permission) {
    switch (permission) {
      case GuidePermission.microphone:
        return ph.Permission.microphone;
      case GuidePermission.location:
        return ph.Permission.locationWhenInUse;
      case GuidePermission.camera:
        return ph.Permission.camera;
      case GuidePermission.backgroundLocationService:
        // Never resolved against the plugin in this phase.
        throw StateError('deferred step has no plugin permission');
    }
  }

  PermissionOutcome _map(ph.PermissionStatus status) {
    switch (status) {
      case ph.PermissionStatus.granted:
      case ph.PermissionStatus.limited:
      case ph.PermissionStatus.provisional:
        return PermissionOutcome.granted;
      case ph.PermissionStatus.denied:
        return PermissionOutcome.denied;
      case ph.PermissionStatus.permanentlyDenied:
      case ph.PermissionStatus.restricted:
        return PermissionOutcome.permanentlyDenied;
    }
  }

  @override
  Future<PermissionOutcome> request(GuidePermission permission) async {
    if (permission == GuidePermission.backgroundLocationService) {
      // Deferred step: never reaches the platform here.
      return PermissionOutcome.denied;
    }
    try {
      return _map(await _pluginPermission(permission).request());
    } catch (_) {
      // A platform without the plugin answers honestly:
      // nothing was granted.
      return PermissionOutcome.denied;
    }
  }

  @override
  Future<PermissionOutcome> status(GuidePermission permission) async {
    if (permission == GuidePermission.backgroundLocationService) {
      return PermissionOutcome.denied;
    }
    try {
      return _map(
        await _pluginPermission(permission)
            .status
            .timeout(AppConfig.effectivePermissionTimeout),
      );
    } catch (_) {
      return PermissionOutcome.denied;
    }
  }

  @override
  Future<bool> openSettings() async {
    try {
      return await ph.openAppSettings().timeout(
            AppConfig.effectivePermissionTimeout,
          );
    } catch (_) {
      return false;
    }
  }
}
