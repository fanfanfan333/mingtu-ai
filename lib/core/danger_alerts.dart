/// Danger alert policy for YOLO detections (step 2).
///
/// Maps detection classes to short, imperative Chinese
/// alerts ("前方有车，请停下。") and rate-limits each category:
/// the same class of danger re-announcing every frame would
/// drown out navigation speech, so a category must cool down
/// before it can speak again. Alerts never give a walking
/// direction (a detection box has no distance) and never use
/// a safe-passage claim.
library;

enum DangerCategory { vehicle, person, other }

const Map<String, DangerCategory> _categoryByLabel = <String, DangerCategory>{
  'car': DangerCategory.vehicle,
  'truck': DangerCategory.vehicle,
  'bus': DangerCategory.vehicle,
  'motorcycle': DangerCategory.vehicle,
  'bicycle': DangerCategory.vehicle,
  'person': DangerCategory.person,
};

DangerCategory dangerCategoryFor(String label) =>
    _categoryByLabel[label] ?? DangerCategory.other;

/// Priority for choosing which category speaks when several
/// are new in the same frame: vehicles first (fast, heavy),
/// then people, then anything else.
int dangerPriority(DangerCategory c) => switch (c) {
      DangerCategory.vehicle => 0,
      DangerCategory.person => 1,
      DangerCategory.other => 2,
    };

String dangerTextFor(DangerCategory category, {String otherName = '障碍物'}) =>
    switch (category) {
      DangerCategory.vehicle => '前方有车，请停下。',
      DangerCategory.person => '前方有人，请停下。',
      DangerCategory.other => '前方检测到$otherName，请停下。',
    };

/// Per-category cooldown gate (debounce against frame spam).
class DangerAlertGate {
  static const Duration cooldown = Duration(seconds: 10);

  final Map<DangerCategory, DateTime> _lastByCategory =
      <DangerCategory, DateTime>{};

  /// True (and records the pass) when [category] may speak at
  /// [now]; false while it is still cooling down.
  bool tryPass(DangerCategory category, DateTime now) {
    final DateTime? last = _lastByCategory[category];
    if (last != null && now.difference(last) < cooldown) return false;
    _lastByCategory[category] = now;
    return true;
  }
}
