/// Single voice scheduler for Mingtu AI v0.1.
///
/// Rule: every module submits speech to this scheduler. No module may call
/// TTS directly. This file contains no TTS call at all on purpose; the
/// Flutter layer is responsible for actually speaking the text that this
/// scheduler marks as `active`, and for reporting completion back via
/// [completeActive].
///
/// Priority: lower number = higher priority. The enum has
/// SIX levels (an earlier draft of this comment listed five
/// -- the table below is the code's actual [priorityOf]):
///   0 emergency       紧急求助
///   1 danger          紧急危险 (imminent hazard)
///   2 obstacleAvoidance / alert  警示 (avoidance + critical
///                     announcements that must be delivered:
///                     recognition results, failures,
///                     permission denials)
///   3 turn            转向
///   4 straight        直行
///   5 info            信息
///
/// Delivery guarantee for critical speech: requests of kind
/// emergency / obstacleAvoidance / alert are submitted with
/// [SpeechRequest.neverExpires] by the app layer, so neither
/// submission nor promotion can drop them as "expired" -- for a
/// blind user a silently dropped safety/failure message is worse
/// than a late one. An alert (level 2) can be interrupted ONLY by a
/// strictly higher priority (an emergency, level 0); the user's own
/// "停下" is not an interruption but an explicit cancelAll(),
/// which is the one sanctioned way to clear everything.
enum SpeechKind {
  emergency,
  danger,
  obstacleAvoidance,
  alert,
  turn,
  straight,
  info
}

int priorityOf(SpeechKind kind) {
  switch (kind) {
    case SpeechKind.emergency:
      return 0;
    case SpeechKind.danger:
      // Imminent-danger alerts (a vehicle/person directly
      // ahead) sit ABOVE every navigation prompt and above
      // general alerts: they interrupt whatever is playing
      // (see SpeechScheduler.submit's interruption rule and
      // the caller's physical playback stop).
      return 1;
    case SpeechKind.obstacleAvoidance:
      return 2;
    case SpeechKind.alert:
      return 2;
    case SpeechKind.turn:
      return 3;
    case SpeechKind.straight:
      return 4;
    case SpeechKind.info:
      return 5;
  }
}

/// What the arbitration does with a NAVIGATION prompt that
/// a hazard announcement interrupted (NAVHAZ M1, spec
/// section 2.6). Hazard and info prompts themselves are
/// never replayed; this only governs navigation items.
enum NavReplay {
  /// Recompute the prompt from the latest GPS fix before
  /// replaying (turn-ahead and entrance-distance prompts):
  /// the distance in the original text is stale the moment
  /// it is interrupted.
  regenerate,

  /// Replay a shortened fixed form (straight / off-route
  /// prompts): the full original wording is not worth
  /// repeating, but the user still needs the gist.
  shortenedReplay,

  /// Never replay (the default for everything else,
  /// including all non-navigation prompts).
  drop,
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

  /// Critical-delivery flag: when true the request NEVER expires
  /// -- submission and promotion must not drop it, however much
  /// time passed. Reserved for safety and failure announcements
  /// (see the SpeechKind documentation). Ordinary prompts keep
  /// the default false and expire as before: a stale "直走" must
  /// never be spoken late.
  final bool neverExpires;

  /// For a turn-ahead prompt: the index of the step it
  /// announces, so the arbitration can regenerate the prompt
  /// against the step geometry after an interruption. Null
  /// for every non-turn prompt.
  final int? navStepIndex;

  /// Interruption handling for navigation prompts
  /// (see [NavReplay]). Defaults to [NavReplay.drop], which
  /// preserves the pre-M1 behaviour for every existing
  /// submission site.
  final NavReplay replay;
  const SpeechRequest({
    required this.id,
    required this.eventId,
    required this.text,
    required this.kind,
    required this.createdAt,
    required this.expiresAt,
    required this.navigationStateVersion,
    this.requiresStraightSegment = false,
    this.neverExpires = false,
    this.navStepIndex,
    this.replay = NavReplay.drop,
  });

  int get priority => priorityOf(kind);
  bool isExpired(DateTime now) => !neverExpires && now.isAfter(expiresAt);
}

class SpeechScheduler {
  static const int straightIntervalMs = 3000;

  SpeechRequest? _active;
  final List<SpeechRequest> _queue = [];
  final List<String> playedLog = [];

  /// Requests that were interrupted, as OBJECTS (NAVHAZ
  /// M1): the arbitration needs the request itself -- its
  /// kind, its step index, its replay policy -- not only an
  /// id. [interruptedLog] below remains as the id view of
  /// this list for the callers (and tests) that only ever
  /// read ids.
  final List<SpeechRequest> interruptedRequests = [];

  /// When each interrupted request was interrupted, by id:
  /// the replay window is measured from the interruption,
  /// not from submission.
  final Map<String, DateTime> _interruptedAt = <String, DateTime>{};

  /// Id view of [interruptedRequests], in interruption
  /// order (derived; the object list is the source of
  /// truth).
  List<String> get interruptedLog =>
      interruptedRequests.map((SpeechRequest r) => r.id).toList();

  /// Record an interruption (single write point so the
  /// object list and the timestamps can never drift).
  void _recordInterrupted(SpeechRequest request, DateTime now) {
    interruptedRequests.add(request);
    _interruptedAt[request.id] = now;
  }

  /// When [request] was interrupted, if it was.
  DateTime? interruptedAtOf(SpeechRequest request) =>
      _interruptedAt[request.id];

  /// The interrupted NAVIGATION requests the arbitration
  /// may still replay (peek -- nothing is removed). Hazard
  /// interruptions stay recorded: the log semantics other
  /// callers rely on (a just-interrupted urgent prompt must
  /// remain recognisable) are unchanged.
  List<SpeechRequest> interruptedNavigationRequests() {
    return interruptedRequests
        .where((SpeechRequest r) =>
            r.replay != NavReplay.drop &&
            (r.kind == SpeechKind.turn ||
                r.kind == SpeechKind.straight ||
                r.kind == SpeechKind.info))
        .toList();
  }

  /// Remove one interrupted request for good: it was either
  /// replayed, dropped as expired, or dropped because its
  /// moment has passed. Exactly-once arbitration is the
  /// caller's discipline built on this + the peek above.
  void discardInterrupted(SpeechRequest request) {
    interruptedRequests.remove(request);
    _interruptedAt.remove(request.id);
  }
  final List<String> droppedExpiredLog = [];
  final List<String> droppedDuplicateLog = [];
  // v0.4: conflicting action instructions (a turn vs an avoidance
  // step) are dropped, never played one after the other.
  final List<String> droppedConflictLog = [];
  // Follow-up: requests cancelled by an explicit stop (voice
  // pause / cancel command). A stopped prompt must never be played
  // afterwards, so cancellation is recorded, not silent.
  final List<String> cancelledLog = [];
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
    // Conflicting actions: a turn and an avoidance step must never be
    // queued to play in sequence. BUT a risk warning must never be
    // silenced by a turn: if the new request is higher priority
    // (avoidance over turn) it interrupts, as the priority rule below
    // does. Only a LOWER-priority conflicting request is dropped here.
    // v0.5 fix: v0.4 dropped avoidance whenever a turn was active,
    // which could hide a danger warning from a blind user.
    bool conflicts(SpeechRequest other) {
      final kinds = {request.kind, other.kind};
      return kinds.contains(SpeechKind.turn) &&
          kinds.contains(SpeechKind.obstacleAvoidance);
    }

    bool lowerPriorityConflict(SpeechRequest other) =>
        conflicts(other) && request.priority >= other.priority;
    if (_active != null && lowerPriorityConflict(_active!)) {
      droppedConflictLog.add(request.id);
      return false;
    }
    if (_queue.any((q) => lowerPriorityConflict(q))) {
      droppedConflictLog.add(request.id);
      return false;
    }
    if (_active == null) {
      _activate(request);
      return true;
    }
    if (request.priority < _active!.priority) {
      _recordInterrupted(_active!, now);
      _active = null;
      _activate(request);
      return true;
    }
    if (request.kind == _active!.kind &&
        (request.kind == SpeechKind.emergency ||
            request.kind == SpeechKind.danger)) {
      // Same-level urgent prompt, different event (a true
      // duplicate of the SAME event was already dropped
      // above): the new danger REPLACES the playing one. It
      // interrupts immediately -- same-level dangers never
      // queue behind each other -- and the interrupted
      // prompt is never replayed.
      _recordInterrupted(_active!, now);
      _active = null;
      _activate(request);
      return true;
    }
    if (request.kind == SpeechKind.emergency ||
        request.kind == SpeechKind.danger) {
      // A QUEUED same-kind urgent prompt is replaced too:
      // only the newest event of that level stays pending.
      for (final SpeechRequest q in _queue
          .where((SpeechRequest q) => q.kind == request.kind)
          .toList()) {
        _queue.remove(q);
        _recordInterrupted(q, now);
      }
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

  /// Disarm the straight 3-second clock ONLY. This
  /// deliberately does NOT touch the active request: whether
  /// a playing prompt is interrupted is the submit()
  /// priority rule's decision, and the physical playback
  /// stop is the caller's sequenced stop before a
  /// high-priority prompt speaks. An earlier version cleared
  /// the active straight prompt here, which destroyed the
  /// very state the preemption logic then inspected -- the
  /// physical stop silently never happened (Codex re-tests
  /// of f951240 and d01a081).
  void pauseStraight() {
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

  /// Cancel everything: the active prompt and every queued prompt.
  ///
  /// Follow-up: a voice "停下 / 取消" must cancel pending
  /// navigation speech, not only the currently playing straight
  /// prompt -- before this, a turn prompt queued behind another
  /// prompt could still be spoken after the user said stop. The
  /// caller stops the actual TTS playback separately and then
  /// submits its own confirmation prompt AFTER calling this, so the
  /// confirmation itself is not cancelled. Returns the cancelled
  /// request ids (active first, then queued in queue order).
  List<String> cancelAll() {
    final List<String> cancelled = <String>[
      if (_active != null) _active!.id,
      for (final SpeechRequest q in _queue) q.id,
    ];
    cancelledLog.addAll(cancelled);
    _active = null;
    _queue.clear();
    _lastStraightPlayedAt = null;
    return cancelled;
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
