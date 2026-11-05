/// Single voice scheduler for Mingtu AI v0.1.
///
/// Rule: every module submits speech to this scheduler. No module may call
/// TTS directly. This file contains no TTS call at all on purpose; the
/// Flutter layer is responsible for actually speaking the text that this
/// scheduler marks as `active`, and for reporting completion back via
/// [completeActive].
///
/// Priority: lower number = higher priority.
///   P0 emergency, P1 high-risk avoidance, P2 turn, P3 straight, P4 info.
enum SpeechKind { emergency, obstacleAvoidance, turn, straight, info }

int priorityOf(SpeechKind kind) {
  switch (kind) {
    case SpeechKind.emergency:
      return 0;
    case SpeechKind.obstacleAvoidance:
      return 1;
    case SpeechKind.turn:
      return 2;
    case SpeechKind.straight:
      return 3;
    case SpeechKind.info:
      return 4;
  }
}

class SpeechRequest {
  final String id;
  final String eventId; // for dedup: same event must not be spoken twice
  final String text;
  final SpeechKind kind;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String navigationStateVersion;
  final bool requiresStraightSegment;
  const SpeechRequest({
    required this.id,
    required this.eventId,
    required this.text,
    required this.kind,
    required this.createdAt,
    required this.expiresAt,
    required this.navigationStateVersion,
    this.requiresStraightSegment = false,
  });

  int get priority => priorityOf(kind);
  bool isExpired(DateTime now) => now.isAfter(expiresAt);
}

class SpeechScheduler {
  static const int straightIntervalMs = 3000;

  SpeechRequest? _active;
  final List<SpeechRequest> _queue = [];
  final List<String> playedLog = [];
  final List<String> interruptedLog = [];
  final List<String> droppedExpiredLog = [];
  final List<String> droppedDuplicateLog = [];
  DateTime? _lastStraightPlayedAt;

  SpeechRequest? get active => _active;
  List<SpeechRequest> get queue => List.unmodifiable(_queue);
  DateTime? get lastStraightPlayedAt => _lastStraightPlayedAt;

  /// Submit a request at [now]. Returns true if it became active or queued.
  /// Expired requests are dropped, never played. Duplicate eventIds that are
  /// still active/queued and unexpired are dropped, never replayed.
  bool submit(SpeechRequest request, DateTime now) {
    if (request.isExpired(now)) {
      droppedExpiredLog.add(request.id);
      return false;
    }
    final duplicate = (_active != null &&
            _active!.eventId == request.eventId &&
            !_active!.isExpired(now)) ||
        _queue.any(
          (q) => q.eventId == request.eventId && !q.isExpired(now),
        );
    if (duplicate) {
      droppedDuplicateLog.add(request.id);
      return false;
    }
    if (_active == null) {
      _activate(request);
      return true;
    }
    if (request.priority < _active!.priority) {
      interruptedLog.add(_active!.id);
      _active = null;
      _activate(request);
      return true;
    }
    _queue.add(request);
    _queue.sort((a, b) {
      final p = a.priority.compareTo(b.priority);
      return p != 0 ? p : a.createdAt.compareTo(b.createdAt);
    });
    return true;
  }

  void _activate(SpeechRequest request) {
    _active = request;
    playedLog.add(request.id);
    if (request.kind == SpeechKind.straight) {
      // The caller sets the timer via recordStraightPlayed; _activate alone
      // does not restart it, so a resumed straight prompt is explicit.
    }
  }

  /// Straight prompts may only be (re)started when the caller confirms:
  /// the current segment is a confirmed straight segment, the navigation
  /// state version still matches, and no risk event is active.
  bool shouldPlayStraight({
    required DateTime now,
    required bool straightSegmentConfirmed,
    required bool riskActive,
  }) {
    if (!straightSegmentConfirmed || riskActive) return false;
    if (_lastStraightPlayedAt == null) return true;
    return now.difference(_lastStraightPlayedAt!).inMilliseconds >=
        straightIntervalMs;
  }

  void recordStraightPlayed(DateTime now) {
    _lastStraightPlayedAt = now;
  }

  /// Pause a straight prompt (e.g. a higher-priority event arrived, a turn
  /// is coming, or the segment is no longer confirmed straight). This
  /// clears the active straight prompt and its timer; it does NOT queue it
  /// for later replay.
  void pauseStraight() {
    if (_active?.kind == SpeechKind.straight) {
      interruptedLog.add(_active!.id);
      _active = null;
    }
    _lastStraightPlayedAt = null;
  }

  /// Resume straight prompts only after re-checking state. Returns false
  /// (and does not restart the timer) if the segment is not confirmed
  /// straight, a risk is active, or the navigation version changed.
  bool resumeStraight({
    required DateTime now,
    required bool straightSegmentConfirmed,
    required bool riskActive,
    required String currentNavigationVersion,
    required String straightNavigationVersion,
  }) {
    if (!straightSegmentConfirmed ||
        riskActive ||
        currentNavigationVersion != straightNavigationVersion) {
      return false;
    }
    _lastStraightPlayedAt = now;
    return true;
  }

  /// Report that the active prompt finished speaking. This does NOT mean
  /// the user completed the physical action; action confirmation is a
  /// separate concern handled by risk / task code.
  void completeActive() {
    _active = null;
  }

  /// Promote the highest-priority queued request that is still valid.
  /// Straight requests are only promoted when the segment is confirmed
  /// straight and no risk is active; expired requests are dropped.
  /// Returns the promoted request, or null.
  SpeechRequest? promoteNext(
    DateTime now, {
    required bool straightSegmentConfirmed,
    required bool riskActive,
  }) {
    if (_active != null) return null;
    while (_queue.isNotEmpty) {
      final next = _queue.removeAt(0);
      if (next.isExpired(now)) {
        droppedExpiredLog.add(next.id);
        continue;
      }
      if (next.kind == SpeechKind.straight &&
          (!straightSegmentConfirmed || riskActive)) {
        droppedExpiredLog.add(next.id);
        continue;
      }
      _activate(next);
      return next;
    }
    return null;
  }
}
