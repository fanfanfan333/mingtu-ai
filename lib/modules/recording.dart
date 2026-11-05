/// Recording management for Mingtu AI v0.1: local only, consent-gated.
///
/// - Recording starts only with an explicit user action (not by default).
/// - After a task, the user is asked whether to keep the recording.
/// - "Keep" saves the managed local session; "delete" deletes the
///   managed local session. This module CANNOT guarantee deletion of
///   copies outside its control (e.g. a system gallery copy made by
///   another app); it must never claim "all copies deleted".
enum RecordingStatus { recording, pendingConsent, saved, deleted, failed }

class RecordingSession {
  final String id;
  final DateTime startedAt;
  DateTime? endedAt;
  RecordingStatus status;
  RecordingSession({required this.id, required this.startedAt})
      : status = RecordingStatus.recording;
}

class RecordingManager {
  RecordingSession? _current;

  RecordingSession? get current => _current;

  RecordingSession start(String id, DateTime now) {
    _current = RecordingSession(id: id, startedAt: now);
    return _current!;
  }

  bool stopPendingConsent(DateTime now) {
    final s = _current;
    if (s == null || s.status != RecordingStatus.recording) return false;
    s.endedAt = now;
    s.status = RecordingStatus.pendingConsent;
    return true;
  }

  /// Returns true only if the session was pending consent and is now saved.
  bool saveWithConsent() {
    final s = _current;
    if (s == null || s.status != RecordingStatus.pendingConsent) return false;
    s.status = RecordingStatus.saved;
    return true;
  }

  /// Deletes the managed local session. Does NOT claim anything about
  /// copies outside this manager's control.
  bool deleteOnDecline() {
    final s = _current;
    if (s == null || s.status != RecordingStatus.pendingConsent) return false;
    s.status = RecordingStatus.deleted;
    return true;
  }
}
