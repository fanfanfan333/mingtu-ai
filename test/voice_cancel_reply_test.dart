/// D5（盲人可用性）纯 Dart 层：驳回撤回意图时的播报文案。
///
/// 这条用例不依赖 widget 树，纯 VM 就能跑（`dart test`），因此在
/// flutter_tester 不可用的机器上也能作为 D5 的验证证据。
/// 端到端的真实播报时间线断言在 voice_cancel_idle_reply_test.dart。
library;

import 'package:mingtu_ai/core/task_manager.dart';
import 'package:mingtu_ai/core/voice_replies.dart';
import 'package:test/test.dart';

void main() {
  test('idle 态撤回意图：回可执行的确认，不出现「重置演示」', () {
    final String text = cancelRejectedSpeech(TaskState.idle);
    expect(text, contains('好的，不去了'),
        reason: 'idle 是最常见的状态，随口反悔必须被当成反悔接受');
    expect(text, isNot(contains('重置演示')),
        reason: '真实盲人手里没有“演示”可重置，这句提示无法执行');
    expect(text, isNot(contains('不能取消')),
        reason: 'idle 没有任务可取消，说“不能取消”只会让人困惑');
    expect(text, contains('去图书馆'),
        reason: '要给出下一步怎么说，盲人用户才知道怎么继续');
  });

  test('终态撤回：告诉用户已经结束，不用再取消', () {
    for (final TaskState state in <TaskState>[
      TaskState.completed,
      TaskState.cancelled,
      TaskState.failed,
    ]) {
      final String text = cancelRejectedSpeech(state);
      expect(text, contains('已经结束'), reason: '$state 应当说任务已结束');
      expect(text, isNot(contains('重置演示')));
    }
  });

  test('其它状态：只说不能取消，不提演示', () {
    for (final TaskState state in <TaskState>[
      TaskState.navigating,
      TaskState.paused,
      TaskState.emergency,
      TaskState.listening,
    ]) {
      final String text = cancelRejectedSpeech(state);
      expect(text, '当前状态不能取消。', reason: '$state 的兜底文案');
    }
  });
}
