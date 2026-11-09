/// The ONE state machine for straight-guidance pacing
/// (Codex re-test of d01a081: pause, timing and resume
/// re-checks used to be three separate mechanisms that could
/// disagree -- a boolean flag here, a direct scheduler resume
/// there, a timer restarted in a third place).
///
/// States:
///   idle               -- no navigation session is running.
///   running            -- straight prompts may tick; exactly
///                         one timer is armed by the caller.
///   held               -- paused by a risk event (or by a
///                         turn in the demo flow). Persistent:
///                         only [recheck] can release it, and
///                         only once no risk is active, no
///                         danger prompt is pending, and the
///                         CURRENT segment is confirmed
///                         straight.
///   suspendedForReroute -- an off-route re-plan is in flight
///                         (or its new tracker is installed but
///                         has not confirmed a straight segment
///                         yet). The old tracker must not be
///                         consulted while suspended; only
///                         [recheck] with a ready NEW tracker
///                         releases it.
///
/// The machine owns no timer itself: [begin] and a successful
/// [recheck] return true exactly once per transition into
/// running, telling the caller to (re)start its single timer.
/// Repeated re-checks while already running return false, so
/// the timer is never armed twice.
enum StraightPacingState { idle, running, held, suspendedForReroute }

class StraightPacingMachine {
  StraightPacingState _state = StraightPacingState.idle;
  String _heldNavVersion = 'nav-v0';
  int _armCount = 0;

  StraightPacingState get state => _state;

  /// Straight ticks are allowed only in the running state.
  bool get canTick => _state == StraightPacingState.running;

  /// How many times the caller was told to (re)start the
  /// timer. A correct integration arms exactly once per
  /// transition into running.
  int get armCount => _armCount;

  /// The navigation version anchored when the current hold
  /// began (exposed for the scheduler's resume bookkeeping).
  String get heldNavVersion => _heldNavVersion;

  /// Begin a navigation session. Returns true when the
  /// caller must start the timer.
  bool begin() {
    if (_state == StraightPacingState.running) return false;
    _state = StraightPacingState.running;
    _armCount++;
    return true;
  }

  /// Enter the persistent hold (risk event, or a demo turn).
  /// The first entry anchors the navigation version; a second
  /// danger during the same hold must not move the anchor.
  void hold(String navVersion) {
    if (_state == StraightPacingState.held) return;
    _state = StraightPacingState.held;
    _heldNavVersion = navVersion;
  }

  /// Suspend for an off-route re-plan.
  void suspendForReroute() {
    _state = StraightPacingState.suspendedForReroute;
  }

  /// The single resume gate. Judged entirely on the state at
  /// THIS moment:
  /// - a risk still active, or a danger/emergency prompt
  ///   still active or queued (its completion callback has
  ///   not run yet), blocks every resume -- straight timing
  ///   never restarts before the danger has finished;
  /// - from a hold, the current segment must be confirmed
  ///   straight; if the navigation version moved on, the
  ///   anchor is re-based and the NEW segment is what gets
  ///   judged (spec 7.7 item 7);
  /// - from a reroute suspension, a NEW tracker must be
  ///   ready (the caller passes trackerReady=false while a
  ///   re-plan is in flight, so the old tracker can never
  ///   release the suspension) and its current segment must
  ///   be confirmed straight.
  /// Returns true exactly on the transition into running.
  bool recheck({
    required bool riskActive,
    required bool dangerPending,
    required bool trackerReady,
    required bool currentSegmentStraight,
    required String currentNavVersion,
  }) {
    if (_state == StraightPacingState.held) {
      if (riskActive || dangerPending) return false;
      _heldNavVersion = currentNavVersion;
      if (!currentSegmentStraight) return false;
      _state = StraightPacingState.running;
      _armCount++;
      return true;
    }
    if (_state == StraightPacingState.suspendedForReroute) {
      if (!trackerReady || riskActive || dangerPending) return false;
      if (!currentSegmentStraight) return false;
      _state = StraightPacingState.running;
      _armCount++;
      return true;
    }
    return false;
  }

  /// End the session (arrival, stop, task end).
  void stop() {
    _state = StraightPacingState.idle;
  }
}
