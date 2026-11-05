/// Continuous-learning REPLACEMENT for Mingtu AI (v0.4).
///
/// Deleted: any automatic change of production safety rules from a
/// single video, a single feedback, or a model judgement.
/// Replacement: a record-only backlog. Failures, uncertain scenes and
/// expired instructions are recorded for offline human review. Recording
/// NEVER changes a risk threshold, a speech rule, a route score or any
/// other production behaviour. There is deliberately no `apply()`
/// method in this file.
library;

class LearningBacklogEntry {
  final String id;
  final String kind; // e.g. 'perception-miss', 'expired-instruction', 'user-cancelled-prompt'
  final String detail;
  final DateTime at;
  const LearningBacklogEntry({
    required this.id,
    required this.kind,
    required this.detail,
    required this.at,
  });
}

class LearningBacklog {
  final List<LearningBacklogEntry> _entries = [];

  List<LearningBacklogEntry> get entries => List.unmodifiable(_entries);

  int get count => _entries.length;

  /// Record-only. Returns the entry; it does not change any rule.
  LearningBacklogEntry record(String id, String kind, String detail, DateTime at) {
    final entry = LearningBacklogEntry(id: id, kind: kind, detail: detail, at: at);
    _entries.add(entry);
    return entry;
  }

  /// By construction, no rule change ever comes out of this backlog
  /// automatically. A human must review entries offline, create a test,
  /// and ship a reviewed code change through the normal release path.
  List<String> get automaticallyAppliedRuleChanges => const [];
}
