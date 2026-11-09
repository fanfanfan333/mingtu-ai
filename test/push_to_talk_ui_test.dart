import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsData;
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/main.dart';

/// Step C push-to-talk UI: the home screen leads with the big
/// status line and the camera area (upper part), then ONE very
/// large push-to-talk button; the original demo panel stays
/// reachable in the scroll region below the button.
///
/// Assertions are behavioural: the button exists at the
/// required size, holding it produces the spoken cue through
/// the scheduler, releasing it runs the existing
/// _startListening path (whose honest unavailable-recogniser
/// feedback is the visible effect in this environment, where
/// no real ASR engine exists).

/// Let the startup engine probes (which run on fake timers)
/// finish, so no timer is pending at teardown.
Future<void> settleStartup(WidgetTester tester) async {
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 1000));
  }
}

void main() {
  group('step C push-to-talk layout', () {
    testWidgets('the push-to-talk button is large and in the fixed zone',
        (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(const MingtuApp());
      await tester.pump();
      await settleStartup(tester);

      // find.text matches substrings, so scope to the exact
      // label of the push-to-talk text widget itself.
      final Finder button = find.text('按住说话', findRichText: true).hitTestable();
      expect(button, findsOneWidget);
      // The text sits in the big tappable block: measure the
      // block (the Container ancestor), not the glyph run.
      final Finder block = find.ancestor(
        of: button,
        matching: find.byType(Container),
      );
      final Size size = tester.getSize(block);
      expect(size.height, greaterThanOrEqualTo(120),
          reason: 'button size: $size');
      expect(size.width, greaterThan(200), reason: 'button size: $size');

      // TalkBack contract: the button block resolves to a
      // semantics node carrying the explicit label.
      final SemanticsData data = tester.getSemantics(block).getSemanticsData();
      handle.dispose();
      expect(data.label, contains('按住说话按钮，按住后说话，松开结束'));
    });

    testWidgets(
        'the camera area placeholder shows while the live view '
        'is closed', (WidgetTester tester) async {
      await tester.pumpWidget(const MingtuApp());
      await tester.pump();
      await settleStartup(tester);

      expect(find.text('摄像头未开启'), findsOneWidget);
      // The placeholder container fills the camera SizedBox:
      // measure the Container ancestor of the placeholder text.
      final Finder area = find.ancestor(
        of: find.text('摄像头未开启'),
        matching: find.byType(Container),
      );
      final Size size = tester.getSize(area);
      expect(size.height, greaterThan(200), reason: 'camera area: $size');
      // The placeholder offers the existing open flow.
      expect(find.text('打开摄像头（YOLO 实时检测）'), findsOneWidget);
    });

    testWidgets(
        'hold speaks the cue; release runs the existing '
        'start-listening path', (WidgetTester tester) async {
      await tester.pumpWidget(const MingtuApp());
      await tester.pump();

      // Press and HOLD: the cue is submitted to the scheduler
      // (it becomes the current prompt) and nothing has tried
      // to listen yet.
      final Finder block = find.ancestor(
        of: find.text('按住说话', findRichText: true),
        matching: find.byType(Container),
      );
      final TestGesture gesture =
          await tester.startGesture(tester.getCenter(block));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('当前提示：请说'), findsOneWidget);
      expect(find.textContaining('语音识别不可用'), findsNothing);

      // RELEASE: _startListening runs; with no recogniser in
      // this environment it logs the unavailable feedback --
      // the same path the demo button uses.
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('语音识别不可用'), findsOneWidget);

      // Settle the simulated speech-completion timers.
      for (int i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 1500));
      }
    });

    testWidgets('demo panel controls stay reachable below the button',
        (WidgetTester tester) async {
      Future<void> tapScrollableText(String text,
          {String? semanticsLabel}) async {
        // Scroll the panel by hand until the control is
        // hit-testable, then tap it. (scrollUntilVisible was
        // tried first and cannot be used here: it resolves
        // the finder through widget(), which throws when a
        // semantics label matches both the Semantics widget
        // and its merged button node.) The semanticsLabel
        // parameter documents which control is meant where
        // the visible text alone is ambiguous.
        final Finder finder = find.text(text).hitTestable();
        final Finder scrollable = find.byWidgetPredicate(
          (Widget w) => w is Scrollable && w.axis == Axis.vertical,
        );
        expect(scrollable, findsOneWidget);
        final ScrollPosition pos =
            tester.state<ScrollableState>(scrollable).position;
        // A control is hit-testable only while it intersects
        // BOTH the scroll viewport and the root viewport (the
        // fixed header clips the overlap). That window can be
        // narrower than the coarse steps a drag produces, so
        // probe the whole extent in fine steps (earlier taps
        // may have left the panel scrolled past this control).
        bool found = false;
        for (double t = 0; t <= pos.maxScrollExtent && !found; t += 40) {
          pos.jumpTo(t);
          await tester.pump();
          found = finder.evaluate().isNotEmpty;
        }
        expect(found, isTrue, reason: 'reachable: $text');
        expect(finder, findsOneWidget, reason: 'control: $text');
        await tester.tap(finder);
        await tester.pump();
      }

      await tester.pumpWidget(const MingtuApp());
      await tester.pump();
      // Let startup settle: engine probes run on fake timers,
      // the camera area finishes its first layout and the
      // scroll region's activity settles so drags move it.
      for (int i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 1000));
      }

      // Walk the demo flow to navigation using only controls
      // inside the scroll region.
      await tapScrollableText('语音开始（演示输入：带我去图书馆）',
          semanticsLabel: '语音开始，演示输入带我去图书馆');
      await tapScrollableText('理解并规划路线');
      await tapScrollableText('开始导航（直行节奏启动）', semanticsLabel: '开始导航');
      expect(find.text('当前任务状态：正在导航'), findsOneWidget);

      // The simulated-danger button is still there and works.
      await tapScrollableText('模拟 YOLO 检测：前方车辆（演示，无摄像头）',
          semanticsLabel: '模拟 YOLO 检测前方车辆');
      expect(find.textContaining('当前提示：前方有机动车'), findsOneWidget);

      // Stop and re-ask live at the top of the scroll region.
      await tapScrollableText('停下');
      expect(find.text('当前任务状态：已暂停'), findsOneWidget);
      await tapScrollableText('重新问目的地');

      for (int i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 1500));
      }
    });
  });
}
