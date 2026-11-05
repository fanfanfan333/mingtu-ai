/// Task state machine for Mingtu AI v0.1.
///
/// Rules (non-negotiable):
/// - Only the transitions listed in [_legal] are allowed.
/// - State is NEVER inferred from free text alone. There is deliberately no
///   `setStateFromText` / `parseState` method in this file.
/// - EMERGENCY never auto-resumes navigation. After EMERGENCY the task must
///   go through WAITING_CONFIRMATION / PAUSED / COMPLETED / FAILED /
///   CANCELLED / IDLE, with an explicit user confirmation, before any new
///   navigation starts.
/// - COMPLETED / FAILED / CANCELLED are terminal except for an explicit
///   reset() back to IDLE.
enum TaskState {
  idle,
  listening,
  understanding,
  planning,
  navigating,
  avoidingObstacle,
  findingEntrance,
  indoorGuidance,
  waitingConfirmation,
  paused,
  degraded,
  completed,
  failed,
  cancelled,
  emergency,
}

class TaskTransition {
  final TaskState from;
  final TaskState to;
  final String trigger;
  final DateTime at;
  const TaskTransition(this.from, this.to, this.trigger, this.at);
}

const Map<TaskState, Set<TaskState>> _legal = {
  TaskState.idle: {TaskState.listening, TaskState.emergency},
  TaskState.listening: {
    TaskState.understanding,
    TaskState.cancelled,
    TaskState.emergency,
  },
  TaskState.understanding: {
    TaskState.planning,
    TaskState.waitingConfirmation,
    TaskState.cancelled,
    TaskState.emergency,
  },
  TaskState.planning: {
    TaskState.navigating,
    TaskState.waitingConfirmation,
    TaskState.failed,
    TaskState.cancelled,
    TaskState.emergency,
  },
  TaskState.navigating: {
    TaskState.avoidingObstacle,
    TaskState.findingEntrance,
    TaskState.paused,
    TaskState.degraded,
    TaskState.waitingConfirmation,
    TaskState.completed,
    TaskState.failed,
    TaskState.cancelled,
    TaskState.emergency,
  },
  TaskState.avoidingObstacle: {
    TaskState.navigating,
    TaskState.paused,
    TaskState.waitingConfirmation,
    TaskState.failed,
    TaskState.cancelled,
    TaskState.emergency,
  },
  TaskState.findingEntrance: {
    TaskState.indoorGuidance,
    TaskState.navigating,
    TaskState.waitingConfirmation,
    TaskState.paused,
    TaskState.failed,
    TaskState.cancelled,
    TaskState.emergency,
  },
  TaskState.indoorGuidance: {
    TaskState.waitingConfirmation,
    TaskState.completed,
    TaskState.paused,
    TaskState.failed,
    TaskState.cancelled,
    TaskState.emergency,
  },
  TaskState.waitingConfirmation: {
    TaskState.planning,
    TaskState.navigating,
    TaskState.avoidingObstacle,
    TaskState.findingEntrance,
    TaskState.indoorGuidance,
    TaskState.paused,
    TaskState.completed,
    TaskState.cancelled,
    TaskState.emergency,
  },
  TaskState.paused: {
    TaskState.navigating,
    TaskState.avoidingObstacle,
    TaskState.findingEntrance,
    TaskState.indoorGuidance,
    TaskState.cancelled,
    TaskState.emergency,
  },
  TaskState.degraded: {
    TaskState.navigating,
    TaskState.paused,
    TaskState.failed,
    TaskState.cancelled,
    TaskState.emergency,
  },
  TaskState.completed: {TaskState.idle},
  TaskState.failed: {TaskState.idle},
  TaskState.cancelled: {TaskState.idle},
  // No direct emergency -> navigating transition: that would be an
  // automatic resume after an emergency, which is forbidden.
  TaskState.emergency: {
    TaskState.waitingConfirmation,
    TaskState.paused,
    TaskState.completed,
    TaskState.failed,
    TaskState.cancelled,
    TaskState.idle,
  },
};

class TaskManager {
  TaskState _state = TaskState.idle;
  String? taskId;
  String? goal;
  final List<TaskTransition> history = [];
  final List<TaskTransition> rejectedAttempts = [];

  TaskState get state => _state;
  bool get isTerminal =>
      _state == TaskState.completed ||
      _state == TaskState.failed ||
      _state == TaskState.cancelled;

  bool canTransitionTo(TaskState next) =>
      _legal[_state]?.contains(next) ?? false;

  /// Returns true only if the transition is legal. Illegal attempts are
  /// recorded in [rejectedAttempts] and do NOT change state.
  bool transitionTo(TaskState next, {String trigger = 'explicit'}) {
    if (!canTransitionTo(next)) {
      rejectedAttempts.add(
        TaskTransition(_state, next, trigger, DateTime.now()),
      );
      return false;
    }
    history.add(TaskTransition(_state, next, trigger, DateTime.now()));
    _state = next;
    return true;
  }

  bool startTask({required String id, required String goalText}) {
    if (_state != TaskState.idle) return false;
    taskId = id;
    goal = goalText;
    return transitionTo(TaskState.listening, trigger: 'startTask');
  }

  /// Explicit reset from a terminal state (or emergency) back to IDLE.
  /// From a non-terminal, non-emergency state this is illegal on purpose:
  /// callers must cancel/fail/complete first.
  bool reset() {
    if (isTerminal || _state == TaskState.emergency) {
      taskId = null;
      goal = null;
      return transitionTo(TaskState.idle, trigger: 'reset');
    }
    return false;
  }
}
