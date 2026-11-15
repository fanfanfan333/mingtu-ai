import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/lens_sample_scheduler.dart';

void main() {
  late DateTime now;
  late LensSampleScheduler scheduler;

  setUp(() {
    now = DateTime(2026);
    scheduler = LensSampleScheduler(now: () => now);
  });

  test('skips an in-flight capture and permits a later capture', () async {
    final Completer<void> pending = Completer<void>();
    int captures = 0;
    Future<void> capture() {
      captures++;
      return pending.future;
    }

    final Future<void> first = scheduler.request(capture);
    now = now.add(const Duration(milliseconds: 600));
    await scheduler.request(capture);
    expect(captures, 1);
    pending.complete();
    await first;
    now = now.add(const Duration(milliseconds: 400));
    await scheduler.request(() async {
      captures++;
    });
    expect(captures, 2);
  });

  test('cool and fast permits a capture at 500 ms', () async {
    int captures = 0;
    Future<void> capture() async {
      captures++;
    }

    await scheduler.request(capture);
    now = now.add(const Duration(milliseconds: 500));
    await scheduler.request(capture);
    expect(captures, 2);
  });

  test('heat requires one second between starts', () async {
    int captures = 0;
    Future<void> capture() async {
      captures++;
    }

    await scheduler.request(capture, appliedFps: 10);
    now = now.add(const Duration(milliseconds: 999));
    await scheduler.request(capture, appliedFps: 10);
    expect(captures, 1);
    now = now.add(const Duration(milliseconds: 1));
    await scheduler.request(capture, appliedFps: 10);
    expect(captures, 2);
  });

  test('720p analysis cap requires one second between starts', () async {
    int captures = 0;
    Future<void> capture() async {
      captures++;
    }

    await scheduler.request(capture, analysisCap720p: true);
    now = now.add(const Duration(milliseconds: 999));
    await scheduler.request(capture, analysisCap720p: true);
    expect(captures, 1);
    now = now.add(const Duration(milliseconds: 1));
    await scheduler.request(capture, analysisCap720p: true);
    expect(captures, 2);
  });

  test('a slow sample requires one second between starts', () async {
    int captures = 0;
    await scheduler.request(() async {
      captures++;
      now = now.add(const Duration(milliseconds: 500));
    });
    now = now.add(const Duration(milliseconds: 499));
    await scheduler.request(() async {
      captures++;
    });
    expect(captures, 1);
    now = now.add(const Duration(milliseconds: 1));
    await scheduler.request(() async {
      captures++;
    });
    expect(captures, 2);
  });

  test('a failed sample releases the in-flight guard', () async {
    await expectLater(
      scheduler.request(() async => throw StateError('capture failed')),
      throwsStateError,
    );
    now = now.add(const Duration(milliseconds: 500));
    int captures = 0;
    await scheduler.request(() async {
      captures++;
    });
    expect(captures, 1);
  });
}
