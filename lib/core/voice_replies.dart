/// Spoken replies for voice command outcomes that the UI layer owns.
///
/// These strings live in a pure-Dart file on purpose: they are user-facing
/// safety copy (a blind user has no screen to fall back on), so they must
/// be unit-testable without a widget harness. `main.dart` stays the caller
/// that decides *which* state applies.
library;

import 'task_manager.dart';

/// D5: the reply for a cancel request that the state machine rejects.
///
/// The old copy was "当前状态不能取消，请先重置演示。" -- "reset the demo"
/// is not an action a real user can take, and idle is the most common
/// state of all (the user simply changes their mind before starting).
/// So the reply is graded by state:
/// - idle: accept the withdrawal, tell them how to come back;
/// - completed / cancelled / failed: nothing left to cancel;
/// - anything else (a live task in a state that has no cancel edge):
///   plain "cannot cancel", without the demo wording.
String cancelRejectedSpeech(TaskState state) {
  if (state == TaskState.idle) {
    return '好的，不去了。需要导航时随时说“去图书馆”。';
  }
  final bool settled = state == TaskState.completed ||
      state == TaskState.cancelled ||
      state == TaskState.failed;
  if (settled) {
    return '任务已经结束，不用再取消。';
  }
  return '当前状态不能取消。';
}
