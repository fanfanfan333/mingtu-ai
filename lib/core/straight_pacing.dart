/// The ONE state machine for straight-guidance pacing
/// (Codex re-test of d01a081: pause, timing and resume
/// re-checks used to be three separate mechanisms that could
/// disagree -- a boolean flag here, a direct scheduler resume
/// there, a timer restarted in a third place).
///
/// Pause reasons are INDEPENDENT (Codex re-test of 926901c:
/// the single-state shape let a risk hold OVERWRITE a reroute
/// suspension, after which the hold branch released straight
/// guidance against the OLD tracker). Two flags, either or
/// both may be set:
///   _riskHeld         -- a risk event (or a turn in the demo
///                         flow) paused straight guidance.
///   _rerouteSuspended -- an off-route re-plan is in flight
///                         (or its new tracker is installed but
///                         has not confirmed a straight segment
///                         yet); the old tracker must not be
///                         consulted while this is set.
/// [hold] sets only the risk reason, [suspendForReroute] only
/// the reroute reason; neither clears the other. Straight
/// guidance resumes only when BOTH reasons are cleared, and
/// a reason clears only under its own conditions in [recheck]
/// (see there). Clearing just one reason is NOT a resume.
///
/// The public [state] is derived from the flags: idle when no
/// session has begun, suspendedForReroute when the reroute
/// reason is set (it dominates the report: it is the stronger
/// pause, and the integration branches keyed on it must keep
/// working), held when only the risk reason is set, running
/// otherwise.
///
/// The machine owns no timer itself: [begin] and a successful
/// [recheck] return true exactly once per transition into
/// running, telling the caller to (re)start its single timer.
/// Repeated re-checks while already running return false, so
/// the timer is never armed twice.
enum StraightPacingState { idle, running, held, suspendedForReroute }

class StraightPacingMachine {
  bool _begun = false;
  bool _riskHeld = false;
  bool _rerouteSuspended = false;
  String _heldNavVersion = 'nav-v0';
  int _armCount = 0;

  /// Derived from the two independent pause reasons (see the
  /// file header): the reroute suspension dominates the
  /// reported state whenever it is set.
  StraightPacingState get state {
    if (!_begun) return StraightPacingState.idle;
    if (_rerouteSuspended) return StraightPacingState.suspendedForReroute;
    if (_riskHeld) return StraightPacingState.held;
    return StraightPacingState.running;
  }

  /// Straight ticks are allowed only in the running state.
  bool get canTick => state == StraightPacingState.running;

  /// True while any pause reason (risk hold, reroute
  /// suspension, or both) is still in force.
  bool get isPaused => _riskHeld || _rerouteSuspended;

  /// How many times the caller was told to (re)start the
  /// timer. A correct integration arms exactly once per
  /// transition into running.
  int get armCount => _armCount;

  /// The navigation version anchored when the current hold
  /// began (exposed for the scheduler's resume bookkeeping).
  String get heldNavVersion => _heldNavVersion;

  /// Begin a NEW navigation session (demo start, or the
  /// first tracker install of a live trip). Returns true when
  /// the caller must start the timer. A session that already
  /// began is never re-armed by begin, and unreleased pause
  /// reasons are never cleared by it: resuming a paused
  /// session is [recheck]'s job alone. Call sites rely on
  /// this -- a re-plan success is routed through the
  /// suspension branch of the install path and never calls
  /// begin while a suspension is in force.
  bool begin() {
    if (_begun) return false;
    _begun = true;
    _armCount++;
    return true;
  }

  /// Set the RISK pause reason (risk event, or a demo turn).
  /// The first entry anchors the navigation version; a second
  /// danger during the same hold must not move the anchor.
  /// Never touches the reroute reason: a risk arriving during
  /// a re-plan leaves the suspension fully in force.
  void hold(String navVersion) {
    if (_riskHeld) return;
    _riskHeld = true;
    _heldNavVersion = navVersion;
  }

  /// Set the REROUTE pause reason (an off-route re-plan is
  /// in flight). Never touches the risk reason.
  void suspendForReroute() {
    _rerouteSuspended = true;
  }

  /// The single resume gate. Judged entirely on the state at
  /// THIS moment:
  /// - a risk still active, or a danger/emergency prompt
  ///   still active or queued (its completion callback has
  ///   not run yet), blocks every resume -- straight timing
  ///   never restarts before the danger has finished;
  /// - the risk reason clears only once the current segment
  ///   is confirmed straight; if the navigation version moved
  ///   on, the anchor is re-based and the NEW segment is what
  ///   gets judged (spec 7.7 item 7);
  /// - the reroute reason clears only once a NEW tracker is
  ///   ready (the caller passes trackerReady=false while a
  ///   re-plan is in flight, so the old tracker can never
  ///   release the suspension) AND its current segment is
  ///   confirmed straight.
  /// Both reasons are judged in the SAME call: a reason whose
  /// conditions are met clears even when the other is not met
  /// yet, but returning true (and arming the caller's timer)
  /// happens only on the one call that clears the LAST reason.
  /// Returns true exactly on the transition into running.
  bool recheck({
    required bool riskActive,
    required bool dangerPending,
    required bool trackerReady,
    required bool currentSegmentStraight,
    required String currentNavVersion,
  }) {
    if (!_begun || !isPaused) return false;
    if (riskActive || dangerPending) return false;
    if (_rerouteSuspended) {
      if (!trackerReady || !currentSegmentStraight) return false;
      _rerouteSuspended = false;
    }
    if (_riskHeld) {
      _heldNavVersion = currentNavVersion;
      if (!currentSegmentStraight) return false;
      _riskHeld = false;
    }
    if (isPaused) return false;
    _armCount++;
    return true;
  }

  /// End the session (arrival, stop, task end): both pause
  /// reasons are dropped with the session itself.
  void stop() {
    _begun = false;
    _riskHeld = false;
    _rerouteSuspended = false;
  }
}
