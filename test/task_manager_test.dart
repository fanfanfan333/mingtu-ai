import 'package:test/test.dart';
import 'package:mingtu_ai/core/task_manager.dart';

void main() {
  test('legal flow: idle -> listening -> understanding -> planning -> navigating', () {
    final m = TaskManager();
    expect(m.startTask(id: 't1', goalText: 'library'), isTrue);
    expect(m.state, TaskState.listening);
    expect(m.transitionTo(TaskState.understanding), isTrue);
    expect(m.transitionTo(TaskState.planning), isTrue);
    expect(m.transitionTo(TaskState.navigating), isTrue);
  });

  test('illegal transition does not change state', () {
    final m = TaskManager();
    // idle -> navigating is illegal.
    expect(m.transitionTo(TaskState.navigating), isFalse);
    expect(m.state, TaskState.idle);
    expect(m.rejectedAttempts.length, 1);
  });

  test('emergency never auto-resumes to navigating', () {
    final m = TaskManager();
    m.startTask(id: 't1', goalText: 'library');
    m.transitionTo(TaskState.understanding);
    m.transitionTo(TaskState.planning);
    m.transitionTo(TaskState.navigating);
    expect(m.transitionTo(TaskState.emergency), isTrue);
    expect(m.transitionTo(TaskState.navigating), isFalse);
    expect(m.state, TaskState.emergency);
    // Explicit confirmation path is allowed.
    expect(m.transitionTo(TaskState.waitingConfirmation), isTrue);
  });

  test('completed is terminal except for explicit reset', () {
    final m = TaskManager();
    m.startTask(id: 't1', goalText: 'library');
    m.transitionTo(TaskState.understanding);
    m.transitionTo(TaskState.planning);
    m.transitionTo(TaskState.navigating);
    expect(m.transitionTo(TaskState.completed), isTrue);
    expect(m.transitionTo(TaskState.navigating), isFalse);
    expect(m.reset(), isTrue);
    expect(m.state, TaskState.idle);
  });
}
