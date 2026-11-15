/// First-launch guide marker factory (UI-A11Y UI-06).
///
/// Conditional export, same pattern as voice_recorder.dart:
/// on a phone (dart:io) a small file in the app support
/// directory persists the marker; elsewhere the
/// unavailable store answers "seen", so the guide never
/// re-runs where it cannot be recorded. The contract is
/// [GuideStore] in core/permission_flow.dart; tests
/// substitute fakes through the debug seam.
library;

import '../core/permission_flow.dart';

export 'guide_store_stub.dart'
    if (dart.library.io) 'guide_store_mobile.dart';

/// Off-device fallback: without storage there is no
/// honest way to know this is a first launch, so the
/// store answers "seen" and the guide + permission flow
/// does not start. Never pretends a write happened.
class UnavailableGuideStore implements GuideStore {
  const UnavailableGuideStore();

  @override
  Future<bool> hasSeenGuide() async => true;

  @override
  Future<void> markGuideSeen() async {}
}
